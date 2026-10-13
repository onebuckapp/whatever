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

# User CSS themes: policy diagnostics, cascade resolution, and managed-block
# serialization. Pure computation, so no store setup — every export is driven
# through the same two-phase buffer protocol the Swift wrapper uses.

import std/[json, sequtils, strutils, unittest]
import ../api/abi
import ../api/theme_api

type ThemeCall = proc (buffer: ptr char, capacity: int32,
    needed: ptr int32): int32 {.closure.}

proc readTheme(call: ThemeCall): JsonNode =
  var needed: int32 = 0
  check call(nil, 0'i32, addr needed) == ErrBufferTooSmall
  var buffer = newString(needed.int)
  var filled: int32 = 0
  check call(addr buffer[0], needed, addr filled) == Ok
  result = parseJson($buffer)

proc readText(call: ThemeCall): string =
  var needed: int32 = 0
  check call(nil, 0'i32, addr needed) == ErrBufferTooSmall
  var buffer = newString(needed.int)
  var filled: int32 = 0
  check call(addr buffer[0], needed, addr filled) == Ok
  result = $buffer
  if result.len > 0 and result[^1] == '\0':
    result.setLen(result.len - 1)

proc checkCss(css: string): JsonNode =
  readTheme(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
    themeCheck(css.cstring, buffer, capacity, needed))

proc diagnosticsOf(css: string): seq[JsonNode] =
  result = @[]
  for diagnostic in checkCss(css)["diagnostics"]:
    result.add(diagnostic)

const TestNodes = """{"nodes": [{"key": "window", "element": "window", "children": [
  {"key": "tabs", "element": "tabs", "id": "tabs", "children": [
    {"key": "tab-active", "element": "tab", "classes": ["tab"], "states": ["active"]},
    {"key": "wrapper", "element": "stack", "children": [
      {"key": "tab-nested", "element": "tab", "classes": ["tab"]}
    ]}
  ]}
]}]}"""

proc resolveCss(css: string, nodes: string = TestNodes): JsonNode =
  readTheme(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
    themeResolve(css.cstring, nodes.cstring, buffer, capacity, needed))

suite "theme check validates stylesheets without ever failing":
  test "supported declarations pass silently":
    let report = checkCss("#tabs { background-color: #1a1b1e; opacity: 0.9; }")
    check report["diagnostics"].len == 0
    check report["rules"].getInt == 1
    check report["declarations"].getInt == 2

  test "empty and nil stylesheets are clean":
    check checkCss("")["diagnostics"].len == 0
    let report = readTheme(proc (buffer: ptr char, capacity: int32,
        needed: ptr int32): int32 = themeCheck(nil, buffer, capacity, needed))
    check report["diagnostics"].len == 0

  test "unknown properties warn and name the property":
    let found = diagnosticsOf(".tab { tab-shine: 3; color: white; }")
    check found.len == 1
    check found[0]["severity"].getStr == "warning"
    check found[0]["property"].getStr == "tab-shine"
    check "tab-shine" in found[0]["message"].getStr

  test "invalid values are errors":
    let found = diagnosticsOf("#tabs { color: notacolor; border-radius: 4em; opacity: lots; }")
    check found.len == 3
    for diagnostic in found:
      check diagnostic["severity"].getStr == "error"

  test "url() references are errors":
    let found = diagnosticsOf(".tab { background-image: url(file:///etc/passwd); }")
    check found.len == 1
    check found[0]["severity"].getStr == "error"
    check "url()" in found[0]["message"].getStr

  test "at-rules warn and contribute no rules":
    let report = checkCss("@media (prefers-color-scheme: dark) { #tabs { color: white; } }")
    check report["rules"].getInt == 0
    let found = report["diagnostics"]
    check found.len == 1
    check found[0]["severity"].getStr == "warning"
    check found[0]["selector"].getStr.startsWith("@media")

  test "broken syntax is one error with a position":
    let found = diagnosticsOf("#tabs { color: ")
    check found.len == 1
    check found[0]["severity"].getStr == "error"
    check found[0]["line"].getInt >= 1
    check found[0]["col"].getInt >= 1

  test "sibling combinators and pseudo-elements warn":
    check diagnosticsOf(".tab + .tab { color: white; }")[0]["severity"].getStr == "warning"
    check diagnosticsOf(".tab::before { color: white; }")[0]["severity"].getStr == "warning"
    check diagnosticsOf(".tab[x] { color: white; }")[0]["severity"].getStr == "warning"

  test "selectors matching nothing warn":
    let found = diagnosticsOf("foobar { color: white; } #nope { color: white; } .tab:asleep { color: white; }")
    check found.len == 3
    for diagnostic in found:
      check diagnostic["severity"].getStr == "warning"
      check "no known interface element" in diagnostic["message"].getStr

  test "important and comments are accepted":
    let report = checkCss("/* theme */ .tab { color: white !important; }")
    check report["diagnostics"].len == 0

  test "oversized input is rejected, not parsed":
    var big = "#tabs { color: white; }"
    while big.len < MaxCssBytes + 100:
      big.add(" .tab { color: white; }")
    var needed: int32 = 0
    check themeCheck(big.cstring, nil, 0'i32, addr needed) == ErrBadInput

suite "theme resolve runs the GTK cascade in Nim":
  test "states gate matching and values canonicalize":
    let styles = resolveCss("""
      .tab { background-color: red; }
      .tab:active { background-color: #00ff00; }
      #tabs .tab { color: white; opacity: 50%; border-radius: 8px; }
    """)["styles"]
    check styles["tab-active"]["background-color"].getStr == "#00ff00"
    check styles["tab-nested"]["background-color"].getStr == "#ff0000"
    check styles["tab-active"]["color"].getStr == "#ffffff"
    check styles["tab-active"]["opacity"].getStr == "0.5"
    check styles["tab-nested"]["border-radius"].getStr == "8px"

  test "id beats class beats element, order breaks ties":
    let styles = resolveCss("""
      tabs { color: red; }
      #tabs { color: blue; }
      #tabs { background-color: black; background-color: white; }
    """)["styles"]
    check styles["tabs"]["color"].getStr == "#0000ff"
    check styles["tabs"]["background-color"].getStr == "#ffffff"

  test "important outranks specificity":
    let styles = resolveCss("""
      #tabs .tab { color: blue; }
      .tab { color: red !important; }
    """)["styles"]
    check styles["tab-active"]["color"].getStr == "#ff0000"

  test "child combinator needs a direct parent":
    let styles = resolveCss("tabs > .tab { color: white; }")["styles"]
    check styles["tab-active"]["color"].getStr == "#ffffff"
    check not styles.hasKey("tab-nested")

  test "shape classes gate pill and attached cells":
    const shaped = """{"nodes": [{"key": "tabs", "element": "tabs", "id": "tabs", "children": [
      {"key": "pill-tab", "element": "tab", "classes": ["tab", "pill"]},
      {"key": "flat-tab", "element": "tab", "classes": ["tab", "attached"]},
      {"key": "group-tab", "element": "tab", "classes": ["tab", "group", "pill"]}
    ]}]}"""
    let styles = resolveCss(
      ".tab.pill { color: white; } .tab.attached { color: black; } " &
      ".tab.group { border-radius: 4px; }", shaped)["styles"]
    check styles["pill-tab"]["color"].getStr == "#ffffff"
    check styles["flat-tab"]["color"].getStr == "#000000"
    check styles["group-tab"]["color"].getStr == "#ffffff"
    check styles["group-tab"]["border-radius"].getStr == "4px"
    check not styles["pill-tab"].hasKey("border-radius")

  test "body aliases the window node":
    let styles = resolveCss("body { background-color: black; }")["styles"]
    check styles["window"]["background-color"].getStr == "#000000"

  test "gradients resolve with canonical stops":
    let styles = resolveCss(
      "#tabs { background-image: linear-gradient(to right, red, rgb(0, 0, 255)); }")["styles"]
    check styles["tabs"]["background-image"].getStr ==
      "linear-gradient(to right, #ff0000, #0000ff)"

  test "single-stop gradients are dropped":
    let styles = resolveCss("#tabs { background-image: linear-gradient(red); }")["styles"]
    check not styles.hasKey("tabs")

  test "unparseable CSS and node JSON are bad input":
    var needed: int32 = 0
    check themeResolve("#tabs { color: ".cstring, TestNodes.cstring,
      nil, 0'i32, addr needed) == ErrBadInput
    check themeResolve("#tabs { color: white; }".cstring, "{oops".cstring,
      nil, 0'i32, addr needed) == ErrBadInput
    check themeResolve("#tabs { color: white; }".cstring, "[]".cstring,
      nil, 0'i32, addr needed) == ErrBadInput

  test "unsupported declarations resolve silently":
    let styles = resolveCss("#tabs { tab-shine: 3; color: white; }")["styles"]
    check styles["tabs"].len == 1
    check styles["tabs"]["color"].getStr == "#ffffff"

suite "theme serialize prints canonical managed CSS":
  test "values canonicalize and selectors sort":
    let text = readText(proc (buffer: ptr char, capacity: int32,
        needed: ptr int32): int32 = themeSerialize(
          """{".tab:active": {"color": "rgb(255,255,255)", "border-radius": "8px"},
              "#tabs": {"background-color": "red"}}""".cstring,
          buffer, capacity, needed))
    check text == "#tabs {\n  background-color: #ff0000;\n}\n" &
      ".tab:active {\n  border-radius: 8px;\n  color: #ffffff;\n}\n"

  test "invalid entries are dropped, empty map prints empty":
    let text = readText(proc (buffer: ptr char, capacity: int32,
        needed: ptr int32): int32 = themeSerialize(
          """{"#tabs": {"bogus-prop": "1", "color": "notacolor"}}""".cstring,
          buffer, capacity, needed))
    check text == ""
    let empty = readText(proc (buffer: ptr char, capacity: int32,
        needed: ptr int32): int32 = themeSerialize("{}".cstring,
          buffer, capacity, needed))
    check empty == ""

  test "serialize output checks clean and resolves identically":
    let text = readText(proc (buffer: ptr char, capacity: int32,
        needed: ptr int32): int32 = themeSerialize(
          """{"#tabs .tab": {"color": "white", "opacity": "50%"}}""".cstring,
          buffer, capacity, needed))
    check diagnosticsOf(text).len == 0
    let styles = resolveCss(text)["styles"]
    check styles["tab-active"]["color"].getStr == "#ffffff"
    check styles["tab-active"]["opacity"].getStr == "0.5"

  test "non-object styles JSON is bad input":
    var needed: int32 = 0
    check themeSerialize("[]".cstring, nil, 0'i32, addr needed) == ErrBadInput
    check themeSerialize("{oops".cstring, nil, 0'i32, addr needed) == ErrBadInput

suite "theme spec publishes the supported surface":
  test "spec lists the registry":
    let spec = readTheme(proc (buffer: ptr char, capacity: int32,
        needed: ptr int32): int32 = themeSpec(buffer, capacity, needed))
    check "tab" in spec["elements"].mapIt(it.getStr)
    check "tabs" in spec["ids"].mapIt(it.getStr)
    check "active" in spec["pseudos"].mapIt(it.getStr)
    for className in ["tab", "group", "pill", "attached"]:
      check className in spec["classes"].mapIt(it.getStr)
    check "background-color" in spec["properties"]["colors"].mapIt(it.getStr)
    check "border-radius" in spec["properties"]["lengths"].mapIt(it.getStr)
    check "opacity" in spec["properties"]["numbers"].mapIt(it.getStr)
    check "background-image" in spec["properties"]["gradients"].mapIt(it.getStr)

suite "theme declarations feed the controls mapping":
  test "supported declarations come back canonical and ordered":
    let document = readTheme(proc (buffer: ptr char, capacity: int32,
        needed: ptr int32): int32 = themeDeclarations(
          "#tabs { color: red; } .tab:active { color: white !important; opacity: 50%; }".cstring,
          buffer, capacity, needed))
    let declarations = document["declarations"]
    check declarations.len == 3
    check declarations[0]["selector"].getStr == "#tabs"
    check declarations[0]["property"].getStr == "color"
    check declarations[0]["value"].getStr == "#ff0000"
    check declarations[0]["important"].getBool == false
    check declarations[1]["selector"].getStr == ".tab:active"
    check declarations[1]["value"].getStr == "#ffffff"
    check declarations[1]["important"].getBool == true
    check declarations[2]["value"].getStr == "0.5"
    check declarations[0]["order"].getInt < declarations[1]["order"].getInt
    check declarations[1]["order"].getInt < declarations[2]["order"].getInt

  test "unsupported and invalid entries are dropped":
    let document = readTheme(proc (buffer: ptr char, capacity: int32,
        needed: ptr int32): int32 = themeDeclarations(
          "#tabs { tab-shine: 3; color: notacolor; border-radius: 8px; }".cstring,
          buffer, capacity, needed))
    let declarations = document["declarations"]
    check declarations.len == 1
    check declarations[0]["property"].getStr == "border-radius"
    check declarations[0]["value"].getStr == "8px"

  test "unparseable CSS is bad input":
    var needed: int32 = 0
    check themeDeclarations("#tabs { color: ".cstring, nil, 0'i32,
      addr needed) == ErrBadInput
