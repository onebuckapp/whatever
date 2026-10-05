# find_api — find-in-page matching C ABI.
#
# The page text comes from the app, which extracts the visible text nodes out
# of the live DOM; the core never sees HTML here. Matching is exact-substring
# search compiled to an `openparser/regex` pattern, so one engine owns both
# autocomplete-adjacent matching and in-page matching, and the app holds no
# matching logic of its own.
#
# Deliberately not the fuzzy matcher: `fuzzyScore` is subsequence matching —
# `"hlo"` matches `"hello"` scattered — which ranks history well but would
# highlight confusing fragments in a page. Find-in-page wants contiguous
# substring hits with predictable next/previous stepping.
#
# Deliberately not Nim-side HTML parsing either: `openparser/html`'s
# `innerText` synthesises spaces between elements and the lexer normalises
# whitespace, so its output has no correspondence to byte ranges in the
# rendered page. Offsets computed over Nim-parsed HTML could not be mapped
# back onto DOM text nodes for highlighting. The app's `TreeWalker`
# extraction is the authoritative segmentation, and the ranges below are
# offsets into exactly the text the app sent.
#
# Case-insensitivity without engine support: `openparser/regex` has no
# `(?i)` flag (an inline flag is a parse error), so a case-folded query
# expands each ASCII letter to a two-way class (`H` becomes `[Hh]`) and
# leaves every other byte, including non-folded scripts, as an exact
# literal.
#
# Diacritics fold before matching (`foldDiacritics`): both the page text and
# the query transliterate Latin diacritics to ASCII, so `șase` and `sase`
# meet in the middle whichever side was typed with the diacritic. Matching
# runs on the folded text and ranges translate back through the offset map,
# so reported offsets still address the original string. There is no
# `std/unidecode` in the stdlib and no transliteration package vendored, so
# the table is hand-rolled: Latin-1 Supplement, Latin Extended-A, and the
# Romanian Extended-B letters. Anything else matches exactly.
#
# Whole words wrap the literal in `\b(?:…)\b`. The engine's `\b` is
# ASCII-`\w`, consistent with the fold above.
#
# Stateless like the filter surface: every call takes the full text, so
# there is no module state and nothing to lock beyond the ABI's
# one-caller-thread contract. Ownership, threading and sync: see api/abi.nim.

import std/[strutils, unicode]
import openparser/json
# Leaf import on purpose: `openparser/regex` re-exports only `vm` and
# `compiler`, so the umbrella's ciphers and format parsers stay out of the
# archive.
import openparser/regex
import ./abi

const
  ## Ceiling on page text one call will scan. The app truncates its
  ## extraction to the same size, so this is a defensive second gate, not
  ## the primary one. Worst case for `findAll` is one match per byte;
  ## bounding the input is what bounds that transient allocation.
  MaxFindTextBytes* = 1_048_576

  ## Upper bound on matches one call returns. Wrapping thousands of spans
  ## is where the page starts to feel it, so the caller caps what it
  ## highlights and `hasMore` tells the UI the count is partial.
  MaxFindMatches* = 2000

proc foldRune*(code: int): string =
  ## ASCII transliteration of one Latin code point, or "" to keep it as is.
  ##
  ## Covers Latin-1 Supplement, Latin Extended-A, and the Romanian
  ## Extended-B letters — the diacritics a find query meets in practice
  ## (`șase` folds to `sase`). Anything else, including non-Latin scripts,
  ## matches exactly as before. Multi-character expansions (`œ` → `oe`,
  ## `ß` → `ss`) are what make the offset map in `foldDiacritics`
  ## necessary rather than nice.
  ##
  ## `×` (U+00D7) and `÷` (U+00F7) sit inside the letter ranges but are not
  ## letters, so they fall through to exact matching.
  case code
  of 0xC0..0xC5: "A"
  of 0xE0..0xE5: "a"
  of 0xC6: "AE"
  of 0xE6: "ae"
  of 0xC7: "C"
  of 0xE7: "c"
  of 0xC8..0xCB: "E"
  of 0xE8..0xEB: "e"
  of 0xCC..0xCF: "I"
  of 0xEC..0xEF: "i"
  of 0xD1: "N"
  of 0xF1: "n"
  of 0xD2..0xD6: "O"
  of 0xF2..0xF6: "o"
  of 0xD8: "O"
  of 0xF8: "o"
  of 0xD9..0xDC: "U"
  of 0xF9..0xFC: "u"
  of 0xDD: "Y"
  of 0xFD, 0xFF: "y"
  of 0xD0: "D"
  of 0xF0: "d"
  of 0xDE: "TH"
  of 0xFE: "th"
  of 0xDF: "ss"
  of 0x100..0x105: "a"
  of 0x106..0x10D: "c"
  of 0x10E..0x111: "d"
  of 0x112..0x11B: "e"
  of 0x11C..0x123: "g"
  of 0x124..0x127: "h"
  of 0x128..0x12F: "i"
  of 0x130: "I"
  of 0x131: "i"
  of 0x132: "IJ"
  of 0x133: "ij"
  of 0x134..0x135: "j"
  of 0x136..0x138: "k"
  of 0x139..0x142: "l"
  of 0x143..0x148: "n"
  of 0x149: "n"
  of 0x14A: "N"
  of 0x14B: "n"
  of 0x14C..0x151: "o"
  of 0x152: "OE"
  of 0x153: "oe"
  of 0x154..0x159: "r"
  of 0x15A..0x161: "s"
  of 0x162..0x167: "t"
  of 0x168..0x173: "u"
  of 0x174..0x175: "w"
  of 0x176..0x177: "y"
  of 0x178: "Y"
  of 0x179..0x17E: "z"
  of 0x17F: "s"
  of 0x218: "S"
  of 0x219: "s"
  of 0x21A: "T"
  of 0x21B: "t"
  else: ""

proc foldDiacritics*(text: string): tuple[folded: string, origOf: seq[int]] =
  ## Folds Latin diacritics to ASCII, remembering where each folded byte
  ## came from: `origOf[b]` is the original byte offset of the source
  ## character holding folded byte `b`.
  ##
  ## Both sides fold — the page text and the query — so `șase` and `sase`
  ## meet in the middle regardless of which side the diacritic was typed
  ## on. Matching runs on the folded text and the ranges translate back
  ## through `origOf`, so the reported offsets still address the original
  ## string the app sent. A folded range ending mid-expansion (the `e` of an
  ## `œ` → `oe`) translates to an empty range, which the caller drops.
  result.folded = ""
  result.origOf = @[]
  var i = 0
  while i < text.len:
    let size = max(1, text.runeLenAt(i))
    let replacement = foldRune(text.runeAt(i).int)
    let piece = if replacement.len > 0: replacement
                else: text[i ..< min(i + size, text.len)]
    for _ in 0 ..< piece.len:
      result.origOf.add(i)
    result.folded.add(piece)
    i += size

proc buildFindPattern*(query: string, matchCase: bool,
                       wholeWords: bool): string =
  ## Compiles a user query to a regex source matching it literally.
  ##
  ## Every regex metacharacter in the query is escaped, so what the user
  ## typed is what the page must contain byte for byte. With `matchCase`
  ## off, each ASCII letter becomes a two-way class (`h` → `[hH]`);
  ## everything else, including non-ASCII bytes, stays an exact literal.
  ## With `wholeWords`, the literal is wrapped in `\b(?:…)\b`.
  ##
  ## Exported for tests: the ABI below pins behaviour end to end, but the
  ## pattern shape is the security-relevant part (a query must never become
  ## a wildcard), so it is asserted directly too.
  const meta = {'\\', '^', '$', '.', '|', '?', '*', '+', '(', ')', '[', ']',
                '{', '}', '-'}
  result = ""
  for character in query:
    if not matchCase and character in {'a'..'z', 'A'..'Z'}:
      result.add('[')
      result.add(character.toLowerAscii())
      result.add(character.toUpperAscii())
      result.add(']')
    elif character in meta:
      result.add('\\')
      result.add(character)
    else:
      result.add(character)
  if wholeWords:
    result = "\\b(?:" & result & ")\\b"

proc findMatches*(text: string, query: string, matchCase: bool,
                  wholeWords: bool, limit: int): tuple[matches: seq[tuple[start: int, stop: int]], total: int] =
  ## All non-overlapping matches of `query` in `text` as half-open byte
  ## ranges into `text`, plus the total count before `limit` truncation.
  ##
  ## Both sides fold diacritics first (`foldDiacritics`), so `șase` meets
  ## `sase` whichever side the diacritic was typed on, and the folded ranges
  ## translate back through the offset map. A folded range ending
  ## mid-expansion is dropped rather than reported short.
  ##
  ## An empty query matches nothing rather than everything: the bar, not
  ## the core, decides when an empty field clears the highlights, and a
  ## core that returned every gap in the document would read as a failure
  ## to Swift.
  if query.len == 0 or text.len == 0:
    return (@[], 0)
  let capped = min(limit, MaxFindMatches)
  let foldedQuery = foldDiacritics(query).folded
  if foldedQuery.len == 0:
    return (@[], 0)
  let (foldedText, origOf) = foldDiacritics(text)
  let found = findAll(buildFindPattern(foldedQuery, matchCase, wholeWords),
                      foldedText)
  var kept: seq[tuple[start: int, stop: int]] = @[]
  var total = 0
  for candidate in found:
    let start = origOf[candidate.start]
    let stop = if candidate.stop < foldedText.len: origOf[candidate.stop]
               else: text.len
    if stop > start:
      total += 1
      if kept.len < capped:
        kept.add((start, stop))
  (kept, total)

proc findDocument*(text: string, query: string, matchCase: bool,
                   wholeWords: bool, limit: int,
                   truncated: bool): JsonNode =
  ## One result document: the kept ranges, the total before truncation,
  ## whether the list is partial, and whether the input itself was cut.
  ##
  ## Built outside the `%*` macro: the match objects are assembled in a
  ## loop, and `%*` cannot see them.
  var matches = newJArray()
  let found = findMatches(text, query, matchCase, wholeWords, limit)
  for (start, stop) in found.matches:
    matches.add(%*{"start": start, "stop": stop})
  result = %*{
    "matches": matches,
    "total": found.total,
    "hasMore": found.total > found.matches.len,
    "truncated": truncated,
  }

proc bcFindMatches*(text: cstring, query: cstring, matchCase: int32,
                    wholeWords: int32, limit: int32, buffer: ptr char,
                    capacity: int32, needed: ptr int32): int32 {.exportc: "bc_find_matches".} =
  ## Finds every occurrence of `query` in `text`, front to back.
  ##
  ## `text` is the page's visible text exactly as the app extracted it, and
  ## the returned `start`/`stop` pairs are BYTE offsets into that text, not
  ## character indices: any non-ASCII in the page needs converting before
  ## use with UTF-16 indices. `matchCase` and `wholeWords` are zero for off,
  ## nonzero for on. `limit` caps the returned ranges (non-positive means
  ## the maximum); `total` still reports the full count and `hasMore` says
  ## the list was cut.
  ##
  ## Text over `MaxFindTextBytes` is scanned only up to the cap and
  ## `truncated` comes back true; the kept offsets stay valid because the
  ## cut is a prefix. An empty query returns an empty list, not an error.
  ## Synchronous, one caller thread at a time. Returns a shared status code.
  if text.isNil:
    setError("find text is missing")
    return ErrBadInput
  let needle = if query.isNil: "" else: $query
  let haystack = $text
  let wanted = if limit <= 0: MaxFindMatches else: min(limit.int, MaxFindMatches)
  try:
    let cut = haystack.len > MaxFindTextBytes
    let scanned = if cut: haystack[0 ..< MaxFindTextBytes] else: haystack
    let document = findDocument(scanned, needle, matchCase != 0,
                                wholeWords != 0, wanted, cut)
    clearError()
    emitJson(document, buffer, capacity, needed)
  except CatchableError as error:
    setError("find_matches: " & error.msg)
    ErrBadInput
