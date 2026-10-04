# Filter list compiler C ABI for the Whatever backend.
#
# Hosts text and a small user-rule subset in, a WebKit content-blocker JSON
# array out. The app compiles that JSON with `WKContentRuleListStore` and
# attaches the result to every page web view; the core never sees WebKit.
#
# Accepted input, one entry per line:
#   * hosts lines: `0.0.0.0 host`, `127.0.0.1 host`, or a bare `host`.
#     Full-line and inline `#` comments and blank lines are skipped, as are
#     `localhost`, bare IPs, single-label names, and malformed entries.
#   * `||domain^...` network rules (anything after the host is ignored, so a
#     path rule degrades to its host rather than failing the line).
#   * `@@||domain^` / `@@domain` exceptions, emitted as trailing
#     `ignore-previous-rules` entries so they cancel the block and cosmetic
#     rules above them for that host and its subdomains.
#   * `##selector` cosmetic rules, emitted as `css-display-none` entries.
#   * `[Adblock Plus ...]` headers and anything else unrecognized are
#     skipped and counted, never fatal: a bundled snapshot must survive one
#     odd line without taking the whole list down.
#
# Host matching anchors the hostname boundary: the host must be followed
# by `/`, `:`, `?`, `#` or the end of the string, so
# `not-ads.example.com.evil.test` never matches a rule for
# `ads.example.com`. A naive substring filter would.
#
# Shaped this way because WebKit's url-filter is not full regex: a `^`
# assertion may only open the pattern, and `(a|b)` disjunctions are not
# supported at all. The scheme boundary is therefore consumed with
# `[^:]+://` instead of `(^|:)//`, and the trailing boundary is two rules
# — one for a boundary character, one for end of string — instead of one
# rule with `([/:?#]|$)`.
#
# Stateless like the QR surface: both exports take the full input every
# time, so there is no module state to migrate and nothing to lock beyond
# the ABI's one-caller-thread contract. Compiling then reading meta parses
# twice; lists are tens of thousands of lines and each pass is well under
# a tenth of a second.
#
# The `inputHashHex` in meta is FNV-1a, a change-detection fingerprint so
# the app can skip recompiling an unchanged list. It is not a security
# hash and must not be presented as one.
#
# Ownership rules:
#   * Nim never hands allocated memory to Swift. The caller owns the
#     buffers it passes in and Nim only writes into them, two-phase.
#   * `bcLastError` copies into a caller-owned buffer, so there is no
#     cross-boundary free to get wrong.
#
# Thread safety:
#   * No module state, but the error slot in abi.nim is still shared, so
#     one caller thread at a time like every other export.
#
# Sync: every call is synchronous and returns before Swift continues.

import std/[sets, strutils]
import openparser/json

# The error channel and the two-phase buffer protocol live in abi.nim so the
# whole ABI has one last-message slot.
import ./abi

const
  FilterResourceTypes = ["script", "image", "style-sheet", "font", "media",
                         "raw"]
    ## Subresource kinds a block rule applies to. `document` and `popup`
    ## are deliberately absent: blocking a top-level navigation to a listed
    ## host turns one bad link into a dead page, while subresource blocking
    ## is what removes the ads and trackers from pages that do load.

type
  FilterCounts* = object
    ## What one pass over the input found. `skipped` counts lines that were
    ## ignored without being an error: comments, blank lines, list headers,
    ## and entries outside the accepted grammar.
    blocks*: int
    cosmetics*: int
    exceptions*: int
    skipped*: int

proc fnv1a64*(text: string): uint64 =
  ## FNV-1a over the raw input bytes. Change detection only.
  result = 14695981039346656037'u64
  for byte in text:
    result = result xor uint64(ord(byte))
    result = result * 1099511628211'u64

proc hashHex*(text: string): string =
  ## Lowercase hex of the input fingerprint, 16 characters.
  toHex(fnv1a64(text)).toLowerAscii()

proc isValidHost*(host: string): bool =
  ## Pragmatic hostname check: lowercase ASCII letters, digits, dots and
  ## hyphens, dotted, with no empty labels and nothing leading or trailing.
  ## Punycode (`xn--`) passes through as ordinary characters, which is
  ## exactly what WebKit matches against.
  if host.len == 0 or '.' notin host:
    return false
  for c in host:
    if c notin {'a' .. 'z', '0' .. '9', '.', '-'}:
      return false
  if host[0] in {'.', '-'} or host[^1] in {'.', '-'}:
    return false
  for label in host.split('.'):
    if label.len == 0 or label[0] == '-' or label[^1] == '-':
      return false
  true

proc normalizeHost*(raw: string): string =
  ## Lowercases and validates; returns "" for anything unusable.
  let host = raw.strip().toLowerAscii()
  if host.len == 0 or host == "localhost" or host.startsWith("localhost."):
    return ""
  if not isValidHost(host):
    return ""
  # An IPv4 literal is not a hostname we ever want to anchor: matching it
  # would block by address rather than by name.
  var dots = 0
  var allNumeric = true
  for c in host:
    if c == '.':
      inc dots
    elif c notin {'0' .. '9'}:
      allNumeric = false
  if allNumeric and dots == 3:
    return ""
  host

proc escapeHost*(host: string): string =
  ## Escapes a validated hostname for the url-filter regex. Validation
  ## restricts the alphabet to letters, digits, dots and hyphens, so the dot
  ## is the only metacharacter that can appear; the replace documents the
  ## assumption rather than trusting it silently.
  result = host.replace(".", "\\.")
  assert '.' notin result.replace("\\.", "")

proc blockPatterns*(host: string): array[2, string] =
  ## The two anchored WebKit url-filters matching the host and its
  ## subdomains, with an optional port, and nothing else: one for a boundary
  ## character after the host, one for the host ending the string. Two rules
  ## because a disjunction would be needed to join them and WebKit does not
  ## compile those. The `^` opens each pattern because WebKit only allows a
  ## start assertion as the first term.
  let middle = "^[^:]+://([^/]*\\.)?" & escapeHost(host)
  [middle & "[/:?#]", middle & "$"]

proc hostsFromLine*(line: string): string =
  ## Extracts the hostname from a hosts-file line whose `#` comment was
  ## already cut: the entry after an IP first token, or the lone token.
  ## Returns "" when the line is not a usable hosts entry.
  let parts = line.splitWhitespace()
  if parts.len == 0:
    return ""
  if parts.len == 1:
    return normalizeHost(parts[0])
  normalizeHost(parts[1])

proc networkHost*(rule: string): string =
  ## Host part of a `||host^...` rule: after the pipes up to the first
  ## `^`, `/`, or end. Options after the caret are ignored.
  if rule.len <= 2 or not rule.startsWith("||"):
    return ""
  var rest = rule[2 .. ^1]
  var stop = rest.len
  for i, c in rest:
    if c in {'^', '/'}:
      stop = i
      break
  if stop == 0:
    return ""
  rest = rest[0 ..< stop]
  # A trailing option separator without a caret, e.g. `||host$third-party`.
  let dollar = rest.find('$')
  if dollar >= 0:
    if dollar == 0:
      return ""
    rest = rest[0 ..< dollar]
  normalizeHost(rest)

type
  CosmeticRule* = object
    ## An element-hiding rule. `domain` is "" for a global `##selector`
    ## and the qualifying host for `domain##selector`.
    domain*: string
    selector*: string

  ParsedFilters* = object
    blocks*: seq[string]
    cosmetics*: seq[CosmeticRule]
    exceptions*: seq[string]
    counts*: FilterCounts

proc parseFilters*(text: string): ParsedFilters =
  ## One pass over the input. First occurrence wins for duplicate hosts;
  ## output order follows input order so identical input always yields
  ## identical JSON.
  var seenBlocks: HashSet[string]
  var seenCosmetics: HashSet[string]
  var seenExceptions: HashSet[string]
  for rawLine in text.splitLines():
    var line = rawLine.strip()
    if line.len == 0 or line[0] == '!' or line[0] == '[':
      inc result.counts.skipped
      continue
    if line.startsWith("@@"):
      # An exception for a `||` rule or a bare host. `networkHost` needs
      # the pipes, so only re-add them when they are not already there:
      # prepending blindly turns `@@||host` into `||||host`, which no
      # longer parses.
      if line.len <= 2:
        inc result.counts.skipped
        continue
      let rest = line[2 .. ^1]
      let host =
        if rest.startsWith("||"): networkHost(rest)
        else: normalizeHost(rest)
      if host.len > 0:
        if host notin seenExceptions:
          seenExceptions.incl(host)
          result.exceptions.add(host)
      else:
        inc result.counts.skipped
      continue
    if line.startsWith("||"):
      if line.len <= 2:
        inc result.counts.skipped
        continue
      let host = networkHost(line)
      if host.len > 0:
        if host notin seenBlocks:
          seenBlocks.incl(host)
          result.blocks.add(host)
      else:
        inc result.counts.skipped
      continue
    let hashes = line.find("##")
    if hashes >= 0:
      # `domain##selector` keeps its qualifier via `if-domain`; a bare
      # `##selector` applies everywhere. `##+js(...)` scriptlets are not a
      # selector WebKit can hide, so they are skipped rather than emitted
      # as a dead rule.
      if hashes + 2 >= line.len:
        inc result.counts.skipped
        continue
      let selector = line[hashes + 2 .. ^1].strip()
      let qualifier =
        if hashes == 0: ""
        else: normalizeHost(line[0 ..< hashes])
      if selector.len == 0 or selector[0] == '+' or
          (hashes > 0 and qualifier.len == 0):
        inc result.counts.skipped
        continue
      let key = qualifier & "##" & selector
      if key notin seenCosmetics:
        seenCosmetics.incl(key)
        result.cosmetics.add(CosmeticRule(domain: qualifier,
                                          selector: selector))
      continue
    let comment = line.find('#')
    if comment >= 0:
      line = line[0 ..< comment].strip()
      if line.len == 0:
        inc result.counts.skipped
        continue
    let host = hostsFromLine(line)
    if host.len > 0:
      if host notin seenBlocks:
        seenBlocks.incl(host)
        result.blocks.add(host)
    else:
      inc result.counts.skipped
  result.counts.blocks = result.blocks.len
  result.counts.cosmetics = result.cosmetics.len
  result.counts.exceptions = result.exceptions.len

proc compileRules*(parsed: ParsedFilters): JsonNode =
  ## Block rules, then cosmetic rules, then trailing exceptions so each
  ## `ignore-previous-rules` entry cancels what came before it for its
  ## host and subdomains.
  result = newJArray()
  for host in parsed.blocks:
    for pattern in blockPatterns(host):
      result.add(%*{
        "trigger": {
          "url-filter": pattern,
          "resource-type": FilterResourceTypes,
          "load-type": ["third-party"]
        },
        "action": {"type": "block"}
      })
  for rule in parsed.cosmetics:
    if rule.domain.len == 0:
      result.add(%*{
        "trigger": {"url-filter": ".*"},
        "action": {"type": "css-display-none", "selector": rule.selector}
      })
    else:
      result.add(%*{
        "trigger": {
          "url-filter": ".*",
          "if-domain": [rule.domain, "*." & rule.domain]
        },
        "action": {"type": "css-display-none", "selector": rule.selector}
      })
  for host in parsed.exceptions:
    result.add(%*{
      "trigger": {
        "url-filter": ".*",
        "if-domain": [host, "*." & host]
      },
      "action": {"type": "ignore-previous-rules"}
    })

proc metaDocument*(text: string, version: string,
                   parsed: ParsedFilters): JsonNode =
  # Each blocked host emits two rules (boundary character, end of string),
  # so ruleCount counts emitted rules while blockCount counts hosts.
  %*{
    "ruleCount": 2 * parsed.blocks.len + parsed.cosmetics.len +
      parsed.exceptions.len,
    "blockCount": parsed.blocks.len,
    "cosmeticCount": parsed.cosmetics.len,
    "exceptionCount": parsed.exceptions.len,
    "skippedLines": parsed.counts.skipped,
    "inputHashHex": hashHex(text),
    "sourceVersion": version
  }

proc bcFilterCompile*(lists: cstring, buffer: ptr char,
                      capacity: cint, needed: ptr cint): cint
                      {.exportc: "bc_filter_compile".} =
  ## Compiles hosts text plus user rules into a WebKit content-blocker JSON
  ## array, written NUL-terminated into the caller-owned `buffer` through
  ## the two-phase protocol (`needed` reports the full length including the
  ## terminator and may be NULL).
  ##
  ## `lists` is the whole filter text (snapshot plus user rules, newline
  ## separated); an empty string compiles to `[]`, which is a valid empty
  ## rule list. A NULL `lists` is refused with `ErrBadInput`.
  ##
  ## The source version travels with `bc_filter_meta`, which echoes it;
  ## the rule JSON itself carries no version.
  ##
  ## Synchronous, one caller thread at a time. Returns a shared status code.
  if lists.isNil:
    setError("filter text is missing")
    return ErrBadInput
  try:
    let document = compileRules(parseFilters($lists))
    clearError()
    emitJson(document, buffer, capacity, needed)
  except CatchableError as error:
    setError("filter_compile: " & error.msg)
    ErrBadInput

proc bcFilterMeta*(lists: cstring, version: cstring, buffer: ptr char,
                   capacity: cint, needed: ptr cint): cint
                   {.exportc: "bc_filter_meta".} =
  ## Counts, input fingerprint and echoed version for the same input
  ## `bc_filter_compile` takes, without building the rule JSON. Lets the
  ## caller skip recompiling (and the app skip recompiling WebKit-side)
  ## when the fingerprint is unchanged.
  ##
  ## Same NULL contract as `bc_filter_compile`. Synchronous, one caller
  ## thread at a time. Returns a shared status code.
  if lists.isNil:
    setError("filter text is missing")
    return ErrBadInput
  let sourceVersion = if version.isNil: "" else: $version
  try:
    let text = $lists
    let document = metaDocument(text, sourceVersion, parseFilters(text))
    clearError()
    emitJson(document, buffer, capacity, needed)
  except CatchableError as error:
    setError("filter_meta: " & error.msg)
    ErrBadInput
