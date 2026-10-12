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

# Tests for the locale C ABI.
#
# The fixture is a Romanian catalog because its three plural forms exercise
# the `Plural-Forms` evaluator: 1 → form 0, 0/2..19 → form 1, 20+/100 →
# form 2. It is compiled through the real `.po` → `.mo` path (openparser on
# both ends), so the suite pins the shipping format, not just the lookup.
# Fuzzy and empty translations must fall back to their msgids: translators
# mark work-in-progress exactly that way.

import std/[os, strutils, unittest]

import openparser/json
import openparser/gettext/po

import ../api/[abi, locale_api]

const fixturePo = """
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"
"Plural-Forms: nplurals=3; plural=(n==1?0:(((n%100>19)||((n%100==0)&&(n!=0)))?2:1));\n"

#. Settings > General > toggle: record main-frame visits in history.
msgctxt "Settings.General"
msgid "Record visited pages"
msgstr "Înregistrează paginile vizitate"

msgid "Open"
msgctxt "Menu.File"
msgstr "Deschide"

msgid "Open"
msgctxt "Dialog.Button"
msgstr "Deschideți"

msgid "one file"
msgid_plural "{n} files"
msgstr[0] "un fișier"
msgstr[1] "{n} fișiere"
msgstr[2] "{n} de fișiere"

msgid "Hello {name}, you have {count} messages"
msgstr "Salut {name}, ai {count} mesaje"

#, fuzzy
msgid "Fuzzy entry"
msgstr "Traducere neconfirmată"

msgid "Empty translation"
msgstr ""
"""

proc fixtureDir(): string =
  result = getTempDir() / "whatever-locale-test"
  if dirExists(result):
    removeDir(result)
  createDir(result / "ro" / "LC_MESSAGES")
  writeFile(result / "src.po", fixturePo)
  var cat = openPoCatalog(result / "src.po")
  let compiled = compilePo(cat)
  close(cat)
  writeMoFile(compiled, result / "ro" / "LC_MESSAGES" / "whatever.mo")

proc readText(document: cstring): string =
  var needed: int32
  check bcLocaleTranslate(document, nil, 0, addr needed) == ErrBufferTooSmall
  check needed > 0
  var text = newString(needed)
  check bcLocaleTranslate(document, addr text[0], needed, nil) == Ok
  text.setLen(needed - 1)
  text

proc trDoc(msgid: string, msgctxt = "", plural = "", n = -1,
           args: JsonNode = nil): string =
  var item = newJObject()
  item["msgid"] = newJString(msgid)
  if msgctxt.len > 0:
    item["msgctxt"] = newJString(msgctxt)
  if plural.len > 0:
    item["plural"] = newJString(plural)
  if n >= 0:
    item["n"] = newJInt(n)
  if not args.isNil:
    item["args"] = args
  readText($item)

proc batchDoc(items: seq[JsonNode]): JsonNode =
  var needed: int32
  let request = $(%*{"items": items})
  check bcLocaleBatch(request.cstring, nil, 0, addr needed) == ErrBufferTooSmall
  check needed > 0
  var text = newString(needed)
  check bcLocaleBatch(request.cstring, addr text[0], needed, nil) == Ok
  text.setLen(needed - 1)
  parseJson(text)

proc getTag(): string =
  var needed: int32
  check bcLocaleGet(nil, 0, addr needed) == ErrBufferTooSmall
  var tag = newString(needed)
  check bcLocaleGet(addr tag[0], needed, nil) == Ok
  tag.setLen(needed - 1)
  tag

suite "locale setup":
  setup:
    discard bcLocaleInit(fixtureDir().cstring)

  test "starts in English with no catalog":
    check getTag() == "en"
    check trDoc("Record visited pages", "Settings.General") ==
      "Record visited pages"

  test "init rejects a missing directory":
    check bcLocaleInit(nil) == ErrBadInput
    check bcLocaleInit("".cstring) == ErrBadInput

  test "set requires init and a tag":
    check bcLocaleSet(nil) == ErrBadInput
    check bcLocaleSet("".cstring) == ErrBadInput

  test "normalizes ro-RO onto the ro catalog":
    check bcLocaleSet("ro-RO".cstring) == Ok
    check getTag() == "ro"

  test "a missing catalog falls back to English, still Ok":
    check bcLocaleSet("xx".cstring) == Ok
    check getTag() == "en"
    check trDoc("Record visited pages", "Settings.General") ==
      "Record visited pages"

  test "a corrupt catalog falls back to English":
    let dir = fixtureDir()
    createDir(dir / "zz" / "LC_MESSAGES")
    writeFile(dir / "zz" / "LC_MESSAGES" / "whatever.mo", "not a catalog")
    check bcLocaleSet("zz".cstring) == Ok
    check getTag() == "en"

suite "locale lookup":
  setup:
    discard bcLocaleInit(fixtureDir().cstring)
    discard bcLocaleSet("ro".cstring)

  test "translates with context":
    check trDoc("Record visited pages", "Settings.General") ==
      "Înregistrează paginile vizitate"

  test "the same msgid differs by context":
    check trDoc("Open", "Menu.File") == "Deschide"
    check trDoc("Open", "Dialog.Button") == "Deschideți"

  test "a missing entry falls back to its msgid":
    check trDoc("No such string", "Settings.General") == "No such string"

  test "a missing context falls back to its msgid":
    check trDoc("Record visited pages", "Other.Screen") ==
      "Record visited pages"

  test "fuzzy and empty translations fall back to their msgids":
    check trDoc("Fuzzy entry") == "Fuzzy entry"
    check trDoc("Empty translation") == "Empty translation"

suite "locale plurals":
  setup:
    discard bcLocaleInit(fixtureDir().cstring)
    discard bcLocaleSet("ro".cstring)

  test "Romanian picks all three forms":
    check trDoc("one file", "", "{n} files", 1) == "un fișier"
    check trDoc("one file", "", "{n} files", 0) == "{n} fișiere"
    check trDoc("one file", "", "{n} files", 2) == "{n} fișiere"
    check trDoc("one file", "", "{n} files", 19) == "{n} fișiere"
    check trDoc("one file", "", "{n} files", 20) == "{n} de fișiere"
    check trDoc("one file", "", "{n} files", 100) == "{n} de fișiere"
    check trDoc("one file", "", "{n} files", 101) == "{n} fișiere"

  test "an untranslated plural falls back to its templates":
    check trDoc("one download", "", "{n} downloads", 1) == "one download"
    check trDoc("one download", "", "{n} downloads", 5) == "{n} downloads"

  test "batch keeps order and skips non-objects":
    var a = newJObject()
    a["msgid"] = newJString("Record visited pages")
    a["msgctxt"] = newJString("Settings.General")
    var b = newJObject()
    b["msgid"] = newJString("one file")
    b["plural"] = newJString("{n} files")
    b["n"] = newJInt(20)
    let document = batchDoc(@[a, b, newJString("junk")])
    check document["texts"].len == 3
    check document["texts"][0].getStr() == "Înregistrează paginile vizitate"
    check document["texts"][1].getStr() == "{n} de fișiere"
    check document["texts"][2].getStr() == ""

suite "locale formatting":
  setup:
    discard bcLocaleInit(fixtureDir().cstring)
    discard bcLocaleSet("ro".cstring)

  test "fills {name} placeholders from args":
    var args = newJObject()
    args["name"] = newJString("Ana")
    args["count"] = newJInt(3)
    check trDoc("Hello {name}, you have {count} messages", "", "", -1,
                args) == "Salut Ana, ai 3 mesaje"

  test "unknown placeholders survive verbatim":
    var args = newJObject()
    args["name"] = newJString("Ana")
    check trDoc("Hello {name}, you have {count} messages", "", "", -1,
                args) == "Salut Ana, ai {count} mesaje"

  test "formatting applies to the English fallback too":
    var args = newJObject()
    args["name"] = newJString("Ana")
    check trDoc("Welcome back, {name}", "", "", -1, args) ==
      "Welcome back, Ana"

suite "locale inventory":
  setup:
    discard bcLocaleInit(fixtureDir().cstring)

  test "lists shipped tags, sorted":
    var needed: int32
    check bcLocaleLanguages(nil, 0, addr needed) == ErrBufferTooSmall
    var text = newString(needed)
    check bcLocaleLanguages(addr text[0], needed, nil) == Ok
    text.setLen(needed - 1)
    check parseJson(text) == %*["ro"]

  test "lists nothing before init":
    discard bcLocaleInit((fixtureDir() & "-missing").cstring)
    var needed: int32
    check bcLocaleLanguages(nil, 0, addr needed) == ErrBufferTooSmall
    var text = newString(needed)
    check bcLocaleLanguages(addr text[0], needed, nil) == Ok
    text.setLen(needed - 1)
    check parseJson(text).len == 0

  test "the table carries singulars under context keys":
    discard bcLocaleSet("ro".cstring)
    var needed: int32
    check bcLocaleTable(nil, 0, addr needed) == ErrBufferTooSmall
    var text = newString(needed)
    check bcLocaleTable(addr text[0], needed, nil) == Ok
    text.setLen(needed - 1)
    let document = parseJson(text)
    check document["lang"].getStr() == "ro"
    check document["strings"]["Settings.General\x04Record visited pages"].getStr() ==
      "Înregistrează paginile vizitate"

  test "the table skips plural entries for the batch path":
    discard bcLocaleSet("ro".cstring)
    var needed: int32
    check bcLocaleTable(nil, 0, addr needed) == ErrBufferTooSmall
    var text = newString(needed)
    check bcLocaleTable(addr text[0], needed, nil) == Ok
    text.setLen(needed - 1)
    check parseJson(text)["strings"].hasKey("one file") == false

  test "the table is empty in English mode":
    var needed: int32
    check bcLocaleTable(nil, 0, addr needed) == ErrBufferTooSmall
    var text = newString(needed)
    check bcLocaleTable(addr text[0], needed, nil) == Ok
    text.setLen(needed - 1)
    let document = parseJson(text)
    check document["lang"].getStr() == "en"
    check document["strings"].len == 0

proc shippedDir(): string =
  ## Compiles the real shipped catalogs through the genuine `.po` → `.mo`
  ## path into a temp dir, mirroring what `make core` ships. Reading from
  ## the source tree (not the build output) keeps the suite hermetic: it
  ## passes on a fresh checkout with no prior build.
  result = getTempDir() / "whatever-locale-shipped"
  if dirExists(result):
    removeDir(result)
  let locale = parentDir(parentDir(parentDir(
    parentDir(currentSourcePath)))) / "locale"
  for lang in ["de", "en", "es", "fr", "it", "pt", "ro", "ru"]:
    createDir(result / lang / "LC_MESSAGES")
    var cat = openPoCatalog(locale / (lang & ".po"))
    let compiled = compilePo(cat)
    close(cat)
    writeMoFile(compiled, result / lang / "LC_MESSAGES" / "whatever.mo")

suite "locale shipped catalogs":
  setup:
    discard bcLocaleInit(shippedDir().cstring)

  test "lists every shipped tag, sorted":
    var needed: int32
    check bcLocaleLanguages(nil, 0, addr needed) == ErrBufferTooSmall
    var text = newString(needed)
    check bcLocaleLanguages(addr text[0], needed, nil) == Ok
    text.setLen(needed - 1)
    check parseJson(text) == %*["de", "en", "es", "fr", "it", "pt", "ro", "ru"]

  test "French treats 0 and 1 as singular":
    discard bcLocaleSet("fr".cstring)
    check trDoc("one visit", "", "{n} visits", 0) == "une visite"
    check trDoc("one visit", "", "{n} visits", 1) == "une visite"
    check trDoc("one visit", "", "{n} visits", 2) == "{n} visites"

  test "Spanish uses the standard two-form rule":
    discard bcLocaleSet("es".cstring)
    check trDoc("one visit", "", "{n} visits", 1) == "una visita"
    check trDoc("one visit", "", "{n} visits", 0) == "{n} visitas"
    check trDoc("one visit", "", "{n} visits", 2) == "{n} visitas"

  test "Italian uses the standard two-form rule":
    discard bcLocaleSet("it".cstring)
    check trDoc("one visit", "", "{n} visits", 1) == "una visita"
    check trDoc("one visit", "", "{n} visits", 0) == "{n} visite"
    check trDoc("one visit", "", "{n} visits", 2) == "{n} visite"

  test "German uses the standard two-form rule":
    discard bcLocaleSet("de".cstring)
    check trDoc("one visit", "", "{n} visits", 1) == "ein Besuch"
    check trDoc("one visit", "", "{n} visits", 0) == "{n} Besuche"
    check trDoc("one visit", "", "{n} visits", 2) == "{n} Besuche"

  test "Portuguese uses the standard two-form rule":
    discard bcLocaleSet("pt".cstring)
    check trDoc("one visit", "", "{n} visits", 1) == "uma visita"
    check trDoc("one visit", "", "{n} visits", 0) == "{n} visitas"
    check trDoc("one visit", "", "{n} visits", 2) == "{n} visitas"

  test "Russian picks all three forms":
    discard bcLocaleSet("ru".cstring)
    check trDoc("one visit", "", "{n} visits", 1) == "{n} посещение"
    check trDoc("one visit", "", "{n} visits", 21) == "{n} посещение"
    check trDoc("one visit", "", "{n} visits", 101) == "{n} посещение"
    check trDoc("one visit", "", "{n} visits", 2) == "{n} посещения"
    check trDoc("one visit", "", "{n} visits", 4) == "{n} посещения"
    check trDoc("one visit", "", "{n} visits", 22) == "{n} посещения"
    check trDoc("one visit", "", "{n} visits", 0) == "{n} посещений"
    check trDoc("one visit", "", "{n} visits", 5) == "{n} посещений"
    check trDoc("one visit", "", "{n} visits", 11) == "{n} посещений"
    check trDoc("one visit", "", "{n} visits", 14) == "{n} посещений"
    check trDoc("one visit", "", "{n} visits", 25) == "{n} посещений"
    check trDoc("one visit", "", "{n} visits", 111) == "{n} посещений"

  test "a context lookup resolves in each new language":
    discard bcLocaleSet("fr".cstring)
    check trDoc("New Tab", "Context.Tab") == "Nouvel onglet"
    discard bcLocaleSet("es".cstring)
    check trDoc("New Tab", "Context.Tab") == "Nueva pestaña"
    discard bcLocaleSet("it".cstring)
    check trDoc("New Tab", "Context.Tab") == "Nuova scheda"
    discard bcLocaleSet("de".cstring)
    check trDoc("New Tab", "Context.Tab") == "Neuer Tab"
    discard bcLocaleSet("ru".cstring)
    check trDoc("New Tab", "Context.Tab") == "Новая вкладка"
    discard bcLocaleSet("pt".cstring)
    check trDoc("New Tab", "Context.Tab") == "Novo separador"

suite "locale bad input":
  setup:
    discard bcLocaleInit(fixtureDir().cstring)

  test "translate rejects nil, garbage, and msgid-less documents":
    check bcLocaleTranslate(nil, nil, 0, nil) == ErrBadInput
    check bcLocaleTranslate("}".cstring, nil, 0, nil) == ErrBadInput
    check bcLocaleTranslate("[]".cstring, nil, 0, nil) == ErrBadInput
    check bcLocaleTranslate("{}".cstring, nil, 0, nil) == ErrBadInput

  test "batch rejects nil, garbage, and item-less documents":
    check bcLocaleBatch(nil, nil, 0, nil) == ErrBadInput
    check bcLocaleBatch("}".cstring, nil, 0, nil) == ErrBadInput
    check bcLocaleBatch("{\"items\":{}}".cstring, nil, 0, nil) ==
      ErrBadInput
