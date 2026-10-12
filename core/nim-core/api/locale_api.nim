# Whatever Browser – Made by Humans from OpenPeeps
#
#     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Locale C ABI for the Whatever backend: translation lives here so every
# shell (macOS, Linux, Windows) shares one engine, one fallback chain, one
# plural evaluator, and one placeholder convention.
#
# Sources are gettext `.po` files under the repo-root `locale/` directory;
# the `msgfmt` tool in `tools/` compiles them to the standard
# `<lang>/LC_MESSAGES/whatever.mo` layout at build time. At runtime this
# module memory-maps a catalog, compiles it to owned strings, and closes
# the mapping straight away, so no file stays open and lookups never touch
# disk.
#
# Conventions (mirrored in `locale/en.po` for translators):
#   * `msgid` is English and is used verbatim at call sites; an untranslated
#     entry returns its msgid, so English needs no catalog and a missing
#     catalog degrades to English rather than failing.
#   * `msgctxt` disambiguates repeats (`Screen.Area`); the table key is
#     `ctx & "\x04" & msgid`, plain msgid without a context. Shells derive
#     the same key for their caches — a concatenation, not translation
#     logic.
#   * Interpolation is `{name}`, filled here from the request's `args`, so
#     every platform formats identically. Unknown placeholders survive
#     verbatim rather than failing the lookup.
#   * Plurals go through openparser's `Plural-Forms` evaluator; `n` picks
#     the form, and the singular/plural templates are the fallback when the
#     entry or the form is missing.
#
# Ownership rules:
#   * Nim never hands allocated memory to the caller. Variable-length
#     results use the two-phase protocol from abi.nim: NULL buffer to learn
#     the size, then an exactly sized caller-owned buffer.
#   * `bcLastError` carries failure messages, as everywhere else.
#
# Thread safety:
#   * Every export touches module-level state (the directory, the active
#     tag, the compiled catalog), so they are neither re-entrant nor
#     thread-safe. Call from one thread only; inside the XPC service that
#     means the service queue, and the whole call is a table lookup.

import std/[algorithm, os, strutils, tables]
import openparser/json
import openparser/gettext/mo

# The error channel lives in abi.nim so the whole ABI has one last-message slot
# and one `bc_last_error` export.
import ./abi

const
  MoDomain* = "whatever.mo"
    ## Catalog file name inside `<lang>/LC_MESSAGES/`.
  CtxSep* = "\x04"
    ## Context separator in table keys, mirroring openparser's `makeKey`.

var localeDir = ""
var activeTag = "en"
var catalog: MoCompiledCatalog
var catalogLoaded = false

proc unloadCatalog() =
  catalogLoaded = false

proc tableKey(msgctxt, msgid: string): string {.inline.} =
  if msgctxt.len == 0: msgid else: msgctxt & CtxSep & msgid

proc moPath(lang: string): string {.inline.} =
  localeDir / lang / "LC_MESSAGES" / MoDomain

proc candidateTags(tag: string): seq[string] =
  ## `ro-RO` tries `ro_RO` then `ro`; a bare tag tries itself. English needs
  ## no catalog and is never loaded.
  let cleaned = tag.strip().replace("-", "_")
  if cleaned.len == 0 or cleaned.toLowerAscii() == "en":
    return @[]
  result.add(cleaned)
  let base = cleaned.split({'_', '@', '.'})[0]
  if base.len > 0 and base != cleaned:
    result.add(base)

proc loadCatalog(tag: string): bool =
  ## Points the active catalog at the first candidate with a catalog file.
  ## Missing files fall back to English (`false`): a broken or absent
  ## translation degrades the UI, never the call.
  unloadCatalog()
  for candidate in candidateTags(tag):
    if fileExists(moPath(candidate)):
      try:
        var mapped = openMoCatalog(moPath(candidate))
        try:
          catalog = compileMo(mapped)
        finally:
          close(mapped)
        catalogLoaded = true
        activeTag = candidate
        clearError()
        return true
      except CatchableError as error:
        setError("locale catalog " & candidate & ": " & error.msg)
        unloadCatalog()
        return false
  catalogLoaded = false
  activeTag = "en"
  clearError()
  false

proc lookup(msgid, msgctxt: string): string =
  if catalogLoaded:
    return translate(catalog, msgid, msgctxt)
  msgid

proc lookupPlural(singular, plural: string, n: int, msgctxt: string): string =
  if catalogLoaded:
    return ntranslate(catalog, singular, plural, n, msgctxt)
  if n == 1: singular else: plural

proc formatArgs(pattern: string, args: JsonNode): string =
  ## Replaces `{name}` placeholders from the `args` object. Non-string
  ## values stringify; unknown placeholders survive verbatim.
  if args.isNil or args.kind != JObject:
    return pattern
  result = pattern
  for key, value in args.pairs:
    let replacement =
      case value.kind
      of JString: value.getStr()
      of JInt: $value.getInt()
      of JFloat: $value.getFloat()
      of JBool: $value.getBool()
      of JNull: ""
      else: $value
    result = result.replace("{" & key & "}", replacement)

proc translateItem(item: JsonNode): string =
  let msgid =
    if item.hasKey("msgid") and item["msgid"].kind == JString: item["msgid"].getStr()
    else: ""
  if msgid.len == 0:
    return ""
  let msgctxt =
    if item.hasKey("msgctxt") and item["msgctxt"].kind == JString: item["msgctxt"].getStr()
    else: ""
  let plural =
    if item.hasKey("plural") and item["plural"].kind == JString: item["plural"].getStr()
    else: ""
  let hasN = item.hasKey("n") and item["n"].kind == JInt
  let pattern =
    if hasN and plural.len > 0: lookupPlural(msgid, plural, int(item["n"].getInt()), msgctxt)
    else: lookup(msgid, msgctxt)
  let args = if item.hasKey("args"): item["args"] else: nil
  formatArgs(pattern, args)

proc bcLocaleInit*(moDir: cstring): int32 {.exportc: "bc_locale_init".} =
  ## Points the module at the directory holding `<lang>/LC_MESSAGES/`
  ## catalogs and resets to English. Each shell passes its own bundle
  ## layout, so Nim never assumes where translations live on any platform.
  ##
  ## Synchronous, one caller thread. Returns an `Ok`/`ErrBadInput` ordinal.
  if moDir.isNil or ($moDir).len == 0:
    setError("locale directory is required")
    return ErrBadInput
  localeDir = $moDir
  unloadCatalog()
  activeTag = "en"
  clearError()
  Ok

proc bcLocaleSet*(tag: cstring): int32 {.exportc: "bc_locale_set".} =
  ## Activates the catalog for a BCP-47 tag (`ro-RO` tries `ro_RO` then
  ## `ro`). A missing catalog falls back to English and still returns `Ok`;
  ## `bc_locale_get` reports what actually loaded, so the caller can tell.
  ##
  ## Synchronous, one caller thread. Returns an `Ok`/`ErrBadInput` ordinal.
  if tag.isNil or ($tag).len == 0:
    setError("language tag is required")
    return ErrBadInput
  if localeDir.len == 0:
    setError("locale directory is not set")
    return ErrBadInput
  discard loadCatalog($tag)
  Ok

proc bcLocaleGet*(buffer: ptr char, capacity: int32, needed: ptr int32): int32
    {.exportc: "bc_locale_get".} =
  ## Copies the active language tag (`ro`, or `en` in English mode),
  ## NUL-terminated, into the caller-owned buffer.
  ##
  ## Two-phase: pass NULL for `buffer` to query the size. Synchronous, one
  ## caller thread. Returns an `Ok` ordinal.
  clearError()
  writeBuffer(activeTag, buffer, capacity, needed)

proc bcLocaleLanguages*(buffer: ptr char, capacity: int32, needed: ptr int32): int32
    {.exportc: "bc_locale_languages".} =
  ## Lists shipped translation tags as a JSON array (`["en", "ro"]`),
  ## sorted, including English: `en.po` names every string, so the picker
  ## can offer it explicitly. Empty before `bc_locale_init`, `[]` when
  ## nothing is shipped.
  ##
  ## Two-phase, synchronous, one caller thread. Returns an `Ok` ordinal.
  var tags: seq[string] = @[]
  if localeDir.len > 0 and dirExists(localeDir):
    for kind, path in walkDir(localeDir):
      if kind == pcDir:
        let lang = splitPath(path).tail
        if not lang.startsWith(".") and fileExists(moPath(lang)):
          tags.add(lang)
  tags.sort()
  clearError()
  var document = newJArray()
  for tag in tags:
    document.add(newJString(tag))
  emitJson(document, buffer, capacity, needed)

proc bcLocaleTranslate*(document: cstring, buffer: ptr char, capacity: int32,
                        needed: ptr int32): int32
    {.exportc: "bc_locale_translate".} =
  ## Translates one item: `{"msgid", "msgctxt"?, "plural"?, "n"?, "args"?}`
  ## and returns the finished string — translated, plural-picked for `n`,
  ## `{name}`-formatted. Missing entries fall back to their templates, so
  ## untranslated text reads as English, never as an error.
  ##
  ## Two-phase, synchronous, one caller thread. A document that is not a
  ## JSON object, or has no `msgid`, is `ErrBadInput`.
  if document.isNil:
    setError("translation document is required")
    return ErrBadInput
  var item: JsonNode
  try:
    item = parseJson($document)
  except CatchableError:
    setError("translation document must be JSON")
    return ErrBadInput
  if item.kind != JObject or not item.hasKey("msgid"):
    setError("translation document needs a msgid")
    return ErrBadInput
  clearError()
  writeBuffer(translateItem(item), buffer, capacity, needed)

proc bcLocaleBatch*(document: cstring, buffer: ptr char, capacity: int32,
                    needed: ptr int32): int32
    {.exportc: "bc_locale_batch".} =
  ## Translates `{"items":[...]}` (same shape as `bc_locale_translate`)
  ## and returns `{"texts":[...]}` in order. One call per screen keeps
  ## plural and formatted strings server-side without per-string IPC.
  ##
  ## Two-phase, synchronous, one caller thread. A document without an
  ## `items` array is `ErrBadInput`.
  if document.isNil:
    setError("translation batch is required")
    return ErrBadInput
  var request: JsonNode
  try:
    request = parseJson($document)
  except CatchableError:
    setError("translation batch must be JSON")
    return ErrBadInput
  if request.kind != JObject or not request.hasKey("items") or
      request["items"].kind != JArray:
    setError("translation batch needs an items array")
    return ErrBadInput
  var texts = newJArray()
  for item in request["items"].items:
    if item.kind == JObject:
      texts.add(newJString(translateItem(item)))
    else:
      texts.add(newJString(""))
  clearError()
  var document = newJObject()
  document["texts"] = texts
  emitJson(document, buffer, capacity, needed)

proc bcLocaleTable*(buffer: ptr char, capacity: int32, needed: ptr int32): int32
    {.exportc: "bc_locale_table".} =
  ## Dumps the active catalog for shell-side caching:
  ## `{"lang": tag, "strings": {key: text}}`, where `key` is the msgid or
  ## `msgctxt & "\x04" & msgid`. Singular entries only — plural entries
  ## resolve through `bc_locale_batch`, which is what picks forms. English
  ## mode yields an empty table: the msgids are the strings.
  ##
  ## Two-phase, synchronous, one caller thread. Returns an `Ok` ordinal.
  var strings = newJObject()
  if catalogLoaded:
    for key, index in catalog.index.pairs:
      let message = catalog.messages[index]
      if message.msgidPlural.len > 0:
        continue
      if message.forms.len > 0 and message.forms[0].len > 0:
        strings[key] = newJString(message.forms[0])
  clearError()
  var document = newJObject()
  document["lang"] = newJString(activeTag)
  document["strings"] = strings
  emitJson(document, buffer, capacity, needed)
