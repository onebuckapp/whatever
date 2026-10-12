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

# msgfmt — compile `locale/<lang>.po` into the standard
# `locale/<lang>/LC_MESSAGES/whatever.mo` layout using openparser's own
# gettext reader and writer, so translators and builds need no external
# gettext install.
#
# Usage: msgfmt <locale-dir>
#
# Leaf tool on purpose: it imports only `openparser/gettext/po`, like the
# core's API modules import only what they use.

import std/[os, strutils]
import openparser/gettext/po

proc compileOne(poPath, localeDir: string): bool =
  let lang = splitFile(poPath).name
  if lang.len == 0 or lang.startsWith("."):
    return true
  let outDir = localeDir / lang / "LC_MESSAGES"
  try:
    createDir(outDir)
  except OSError as e:
    stderr.writeLine("msgfmt: cannot create " & outDir & ": " & e.msg)
    return false
  var cat: PoCatalog
  try:
    cat = openPoCatalog(poPath)
  except PoParseError as e:
    stderr.writeLine("msgfmt: " & poPath & ": " & e.msg)
    return false
  let compiled = compilePo(cat)
  close(cat)
  try:
    writeMoFile(compiled, outDir / "whatever.mo")
  except IOError as e:
    stderr.writeLine("msgfmt: cannot write " & outDir / "whatever.mo" & ": " & e.msg)
    return false
  echo(poPath & " -> " & outDir / "whatever.mo")
  return true

proc main(): int =
  if paramCount() != 1:
    stderr.writeLine("usage: msgfmt <locale-dir>")
    return 1
  let localeDir = paramStr(1)
  if not dirExists(localeDir):
    stderr.writeLine("msgfmt: no such directory: " & localeDir)
    return 1
  var ok = true
  var count = 0
  for poPath in walkFiles(localeDir / "*.po"):
    inc(count)
    ok = compileOne(poPath, localeDir) and ok
  if count == 0:
    echo("msgfmt: no .po files in " & localeDir & " (English needs none: msgids are English)")
  return if ok: 0 else: 1

quit(main())
