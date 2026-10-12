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

# check_tr — every translation literal in Swift sources must exist in English.
#
# Scans `macos/Sources/**/*.swift` for `tr("msgid")` and `LocaleItem("msgid")`
# first-argument literals and fails when any is missing from `locale/en.po`.
# xgettext does not parse Swift, so this is the extractor's honest half:
# translators never silently lose a string.
#
# Usage: nim r core/nim-core/tools/check_tr.nim [repo-root]
# (from anywhere; the root defaults to this file's checkout. Exit 1 on
# missing msgids.)
#
# Leaf tool on purpose: stdlib only, like msgfmt.nim imports only
# `openparser/gettext/po`.

import std/[algorithm, os, sets, strutils, tables, unicode]

const
  sourcesDir = "macos" / "Sources"
  englishPo = "locale" / "en.po"

proc defaultRoot(): string =
  ## The checkout root, derived from this file's compile-time path so the
  ## tool runs from any working directory: tools/ -> nim-core/ -> core/ ->
  ## root. An explicit argument always wins; see `main`.
  let here = expandFilename(currentSourcePath())
  parentDir(parentDir(parentDir(parentDir(here))))

proc unescape(literal: string): string =
  ## Swift escapes that occur in msgids: \" and \\ everywhere, \u{...}
  ## where the source spells a non-ASCII character as an escape (the
  ## runtime string is identical either way, so the template holds the
  ## literal character). Anything fancier belongs in a comment, not a
  ## lookup key. Order matters and mirrors the Python checker this
  ## replaces: \u{...} first, then the single-character escapes.
  result = newStringOfCap(literal.len)
  var i = 0
  while i < literal.len:
    if literal[i] == '\\' and i + 1 < literal.len:
      case literal[i + 1]
      of '"': result.add('"'); i += 2
      of '\\': result.add('\\'); i += 2
      of 'n': result.add('\n'); i += 2
      of 't': result.add('\t'); i += 2
      of 'u':
        let brace = i + 2
        if brace < literal.len and literal[brace] == '{':
          var j = brace + 1
          while j < literal.len and literal[j] in HexDigits: inc j
          if j < literal.len and literal[j] == '}' and j > brace + 1:
            result.add(Rune(parseHexInt(literal[brace + 1 ..< j])))
            i = j + 1
          else:
            result.add('\\'); inc i
        else:
          result.add('\\'); inc i
      else:
        result.add('\\'); inc i
    else:
      result.add(literal[i]); inc i

proc scanLine(line: string, found: var Table[string, seq[string]],
              location: string) =
  ## One source line: every `tr("...")` / `LocaleItem("...")` literal, in
  ## left-to-right order. The scan is deliberately the checker's regex
  ## spelled out (`tr(`/`LocaleItem(`, blanks, a quoted literal with
  ## backslash escapes): same matches, same misses. Doc comments may quote
  ## tr() usage as an example; only code counts, so callers skip `//` lines.
  const needles = ["tr(", "LocaleItem("]
  var i = 0
  while i < line.len:
    var best = -1
    var bestLen = 0
    for n in needles:
      let p = line.find(n, i)
      if p >= 0 and (best < 0 or p < best):
        best = p
        bestLen = n.len
    if best < 0:
      return
    var j = best + bestLen
    while j < line.len and line[j] in {' ', '\t', '\r', '\n', '\x0B', '\x0C'}:
      inc j
    if j < line.len and line[j] == '"':
      var lit = newStringOfCap(32)
      var k = j + 1
      var closed = false
      while k < line.len:
        if line[k] == '\\' and k + 1 < line.len:
          lit.add(line[k])
          lit.add(line[k + 1])
          k += 2
        elif line[k] == '"':
          closed = true
          inc k
          break
        else:
          lit.add(line[k])
          inc k
      if closed:
        found.mgetOrPut(unescape(lit), @[]).add(location)
        i = k
      else:
        i = best + 1
    else:
      i = best + 1

proc templateMsgids(poPath: string): HashSet[string] =
  ## Every non-empty msgid in the template, continuations joined. The
  ## header's empty msgid never lands in the set.
  result = initHashSet[string]()
  var current = ""
  var inMsgid = false
  for line in lines(poPath):
    if line.len >= 8 and line.startsWith("msgid \"") and line.endsWith("\""):
      current = line[7 .. ^2]
      inMsgid = true
    elif inMsgid and line.len >= 2 and line[0] == '"' and line[^1] == '"':
      current.add(line[1 .. ^2])
    else:
      if inMsgid:
        if current.len > 0:
          result.incl(unescape(current))
        inMsgid = false
        current = ""
  if inMsgid and current.len > 0:
    result.incl(unescape(current))

proc sourceMsgids(sources, root: string): Table[string, seq[string]] =
  result = initTable[string, seq[string]]()
  var files: seq[string] = @[]
  for path in walkDirRec(sources):
    if path.endsWith(".swift"):
      files.add(path)
  files.sort()
  for path in files:
    let rel = relativePath(path, root)
    var lineno = 0
    for line in lines(path):
      inc lineno
      if line.strip().startsWith("//"):
        continue
      scanLine(line, result, rel & ":" & $lineno)

proc main(): int =
  var root = defaultRoot()
  if paramCount() >= 1:
    root = paramStr(1)
  let english = root / englishPo
  if not fileExists(english):
    stderr.writeLine("check-tr: no English source at " & english)
    return 1
  let tmpl = templateMsgids(english)
  let found = sourceMsgids(root / sourcesDir, root)
  var missing: seq[string] = @[]
  for msgid in found.keys:
    if msgid notin tmpl:
      missing.add(msgid)
  if missing.len == 0:
    echo("check-tr: all translation literals are in en.po")
    return 0
  missing.sort()
  for msgid in missing:
    echo("missing msgid \"" & msgid & "\" at:")
    for location in found[msgid]:
      echo("  " & location)
  return 1

quit(main())
