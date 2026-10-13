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

# theme_api — user CSS themes for the application chrome.
#
# Advanced users customize the interface with a CSS-like syntax (GTK-style:
# element names, `#ids`, `.classes`, `:states`) instead of only color
# pickers and sliders. The openparser CSS module does the lexing and
# parsing (`parseCss` into an AST); this module owns everything
# Whatever-specific on top:
#
#   * the parsing policy: which selectors, properties and functions survive
#     (`bc_theme_check` reports what did not, and why, as diagnostics the
#     editor underlines),
#   * the cascade: specificity, source order and `!important` resolved here
#     in Nim (`bc_theme_resolve`), so macOS and a future Linux shell can
#     never disagree about what a stylesheet means,
#   * the managed block: `bc_theme_serialize` prints structured settings
#     back as canonical CSS, which is what makes the editor and the
#     pickers/sliders two-way (controls regenerate the managed block,
#     hand-written rules parse back into the controls).
#
# Import discipline: only the parser and AST leaf modules. The `openparser/css`
# umbrella would drag in the MDN syntax tables (~460KB of JSON) for the
# general-purpose validator, which this surface does not need: the supported
# property set is small and each value shape has its own canonicalizer
# below, which validates precisely by construction. Likewise only
# `openparser/colors/{types,parse}` for color canonicalization.
#
# Nothing here touches the store: pure computation over strings, like the
# spotlight hint. Fail-open throughout — an invalid declaration is skipped
# with a diagnostic, never fatal.

import std/[algorithm, json, math, sequtils, strformat, strutils, tables]
import openparser/css/ast
import openparser/css/parser
import openparser/colors/types
import openparser/colors/parse
import ./abi

const
  MaxCssBytes* = 262144
    ## 256 KiB of theme CSS is far beyond sane; past that the input is
    ## rejected rather than parsed.
  MaxNestingDepth = 32

  KnownElements = ["window", "body", "tabs", "tab", "toolbar", "addressbar",
    "dropdown", "bookmarkbar", "bookmark", "page", "crawlbar", "background",
    "bubble"]
  KnownIds = ["tabs", "toolbar", "addressbar", "dropdown", "bookmarkbar",
    "page", "crawlbar", "background"]
  KnownClasses = ["tab", "group", "pill", "attached"]
    ## `group` marks merged split cells (`.tab.group`); `pill` and
    ## `attached` track the strip's shape (`.tab.pill`), so a theme can
    ## answer the shape the controls pick.
  KnownPseudos = ["active", "hover", "selected", "focus", "open"]

  ColorProperties = ["background-color", "color", "border-color"]
  LengthProperties = ["border-radius", "font-size", "border-width"]
  NumberProperties = ["opacity"]
  GradientProperties = ["background-image"]

type
  ThemeDiagnostic* = object
    ## One editor-facing finding. `selector` and `property` locate the
    ## declaration for underlining (the AST carries no line numbers, so the
    ## editor maps these back to its own token ranges); `line`/`col` are
    ## only set for whole-stylesheet syntax errors, where the parser knows
    ## the position.
    selector*: string
    property*: string
    message*: string
    severity*: string
    line*: int
    col*: int

  Specificity* = tuple[a, b, c: int]

  MatchedDeclaration* = object
    property*: string
    canonical*: string
    important*: bool
    specificity*: Specificity
    order*: int

  ThemeNode* = object
    key*: string
    element*: string
    id*: string
    classes*: seq[string]
    states*: seq[string]
    children*: seq[ThemeNode]

proc themePolicy*(): CssPolicy =
  ## The parsing policy: permissive enough to *see* everything (so every
  ## skipped construct gets a diagnostic), guarded only against pathological
  ## input. The Whatever-specific allow-list lives in the pass below, not in
  ## the parser, because a silently skipped declaration cannot be explained
  ## to the user.
  result = defaultPolicy()
  result.maxNestingDepth = MaxNestingDepth

proc isColorProperty*(property: string): bool =
  property in ColorProperties

proc isLengthProperty*(property: string): bool =
  property in LengthProperties

proc isNumberProperty*(property: string): bool =
  property in NumberProperties

proc isGradientProperty*(property: string): bool =
  property in GradientProperties

proc isSupportedProperty*(property: string): bool =
  ## The v1 subset: colors, three lengths, opacity, and linear gradients.
  ## Everything else parses but is skipped with a warning.
  isColorProperty(property) or isLengthProperty(property) or
    isNumberProperty(property) or isGradientProperty(property)

proc supportedPropertyNames*(): seq[string] =
  ColorProperties.toSeq & LengthProperties.toSeq &
    NumberProperties.toSeq & GradientProperties.toSeq

proc canonicalColor*(rawValue: string, canonical: var string): bool =
  ## Parses any CSS color (hex, rgb(), hsl(), named, ...) and renders it as
  ## lowercase `#rrggbb`, with an alpha suffix when not opaque — the shape
  ## the Swift side turns into a color directly.
  try:
    let color: Color = parseColor(rawValue.strip())
    if not color.valid:
      return false
    proc hexByte(value: float): string =
      fmt"{int((min(max(value, 0.0), 1.0) * 255.0).round()):02x}"
    canonical = "#" & hexByte(color.r) & hexByte(color.g) & hexByte(color.b)
    if color.a < 0.999:
      canonical.add(hexByte(color.a))
    true
  except CatchableError:
    false

proc canonicalLength*(rawValue: string, canonical: var string): bool =
  ## Pixels or a unitless zero, rendered as `<number>px`. Other units are
  ## rejected: the chrome measures in points and silently converting `em`
  ## against an unknown base would lie about the result.
  let text = rawValue.strip().toLowerAscii()
  var numberPart = text
  if text.endsWith("px"):
    numberPart = text[0 ..< ^2].strip()
  try:
    let value = parseFloat(numberPart)
    if text.endsWith("px") or value == 0.0:
      if text.len > numberPart.len and not text.endsWith("px"):
        return false
      canonical = $(if value == 0.0: 0.0 else: value)
      if canonical.endsWith(".0"):
        canonical = canonical[0 ..< ^2]
      canonical.add("px")
      return true
  except ValueError:
    discard
  false

proc canonicalOpacity*(rawValue: string, canonical: var string): bool =
  ## A 0..1 number or a percentage, rendered as a 0..1 number. Out-of-range
  ## values clamp the CSS way rather than failing.
  let text = rawValue.strip().toLowerAscii()
  try:
    var value: float
    if text.endsWith("%"):
      value = parseFloat(text[0 ..< ^1].strip()) / 100.0
    else:
      value = parseFloat(text)
    value = min(max(value, 0.0), 1.0)
    canonical = $value
    true
  except ValueError:
    false

proc significantArgs*(args: seq[CssValue]): seq[CssValue] =
  ## Drops inter-token whitespace so gradient argument lists are comparable.
  for arg in args:
    if arg.kind == cvkPreserved and arg.preservedValue.strip() == "":
      continue
    result.add(arg)

proc splitTopLevel*(args: seq[CssValue]): seq[seq[CssValue]] =
  ## Splits a function argument list on top-level commas.
  result = @[@[]]
  for arg in significantArgs(args):
    if arg.kind == cvkPreserved and arg.preservedValue == ",":
      result.add(@[])
    else:
      result[^1].add(arg)

proc identOf*(value: CssValue): string =
  if value.kind == cvkIdent: value.identValue.toLowerAscii() else: ""

proc isValidDirection*(words: seq[string]): bool =
  ## `to <side>{1,2}` with a real CSS gradient direction.
  if words.len == 0 or words[0] != "to":
    return false
  let sides = words[1 ..^ 1]
  if sides.len == 1:
    return sides[0] in ["top", "bottom", "left", "right"]
  if sides.len == 2:
    let vertical = (sides[0] in ["top", "bottom"]) != (sides[1] in ["top", "bottom"])
    let horizontal = (sides[0] in ["left", "right"]) != (sides[1] in ["left", "right"])
    return vertical and horizontal and
      ((sides[0] in ["top", "bottom"]) != (sides[0] in ["left", "right"]))
  false

proc canonicalGradient*(components: seq[CssValue], canonical: var string): bool =
  ## Only `linear-gradient()` with bare color stops. `url()` is blocked —
  ## image backgrounds would read arbitrary local files — and stop positions
  ## wait for a later version. Renders canonical `linear-gradient(to …, #…, #…)`.
  if components.len != 1 or components[0].kind != cvkFunction:
    return false
  let fn = components[0]
  if fn.funcName.toLowerAscii() != "linear-gradient":
    return false
  let groups = splitTopLevel(fn.args)
  if groups.len < 2:
    ## At least two stops; a single stop is not a gradient.
    return false
  var direction = "to bottom"
  var firstStop = 0
  if groups[0].len > 0 and identOf(groups[0][0]) == "to":
    let words = groups[0].mapIt(identOf(it))
    if words.anyIt(it == ""):
      return false
    if not isValidDirection(words):
      return false
    direction = words.join(" ")
    firstStop = 1
  elif groups[0].len == 1 and groups[0][0].kind == cvkDimension and
      groups[0][0].dimUnit.toLowerAscii() == "deg":
    var degrees = $groups[0][0].dimFloat
    if degrees.endsWith(".0"):
      degrees = degrees[0 ..< ^2]
    direction = degrees & "deg"
    firstStop = 1
  elif groups[0].len == 1 and groups[0][0].kind == cvkNumber:
    ## A bare number where a direction belongs is a typo, not a color.
    return false
  var stops: seq[string] = @[]
  for i in firstStop ..< groups.len:
    if groups[i].len != 1:
      return false
    var stop = ""
    if not canonicalColor(serializeComponentValue(groups[i][0]), stop):
      return false
    stops.add(stop)
  if stops.len < 2:
    return false
  canonical = "linear-gradient(" & direction & ", " & stops.join(", ") & ")"
  true

proc containsBlockedFunction*(components: seq[CssValue]): bool =
  ## `url()` anywhere in a value disqualifies the declaration: backgrounds
  ## must not become arbitrary file reads.
  for component in components:
    case component.kind
    of cvkFunction:
      if component.funcName.toLowerAscii() == "url":
        return true
      if containsBlockedFunction(component.args):
        return true
    of cvkUrl:
      return true
    of cvkBlock:
      if containsBlockedFunction(component.blockValues):
        return true
    else:
      discard
  false

proc canonicalValue*(property: string, decl: CssNode, canonical: var string): bool =
  if isColorProperty(property):
    return canonicalColor(decl.rawValue, canonical)
  if isLengthProperty(property):
    return canonicalLength(decl.rawValue, canonical)
  if isNumberProperty(property):
    return canonicalOpacity(decl.rawValue, canonical)
  if isGradientProperty(property):
    return canonicalGradient(decl.valueComponents, canonical)
  false

type
  SelectorSupport* = enum
    ssSupported
    ssUnsupportedCombinator
    ssUnsupportedFeature
    ssMatchesNothing

proc splitCompounds*(parts: seq[string]): tuple[compounds: seq[seq[string]], combinators: seq[string]] =
  ## Splits selector parts into compounds joined by combinators. `" "` is
  ## the descendant combinator, `">"` the child one; `+`/`~`/`||` are
  ## reported upstream as unsupported.
  var compounds: seq[seq[string]] = @[@[]]
  var combinators: seq[string] = @[]
  for part in parts:
    if part in [">", "+", "~", "||", " "]:
      combinators.add(part)
      compounds.add(@[])
    else:
      compounds[^1].add(part)
  (compounds, combinators)

proc checkSelector*(node: CssNode): SelectorSupport =
  ## Classifies one comma-separated selector: structurally unsupported
  ## (combinators beyond descendant/child, attribute selectors,
  ## pseudo-elements), matching nothing in the known registry, or fine.
  ## Unknown classes are allowed through — nodes carry the classes Swift
  ## sends, so a future node may match — but unknown elements, ids and
  ## pseudo-classes can never match and are said so.
  let (compounds, combinators) = splitCompounds(node.parts)
  for combinator in combinators:
    if combinator notin [" ", ">"]:
      return ssUnsupportedCombinator
  for compound in compounds:
    if compound.len == 0:
      return ssUnsupportedFeature
    for part in compound:
      if part.startsWith("::"):
        return ssUnsupportedFeature
      if part.startsWith("["):
        return ssUnsupportedFeature
  for compound in compounds:
    for part in compound:
      if part == "*":
        continue
      if part.startsWith("#"):
        if part[1 ..^ 1].toLowerAscii() notin KnownIds:
          return ssMatchesNothing
      elif part.startsWith("."):
        if part[1 ..^ 1].toLowerAscii() notin KnownClasses:
          discard
      elif part.startsWith(":"):
        if part[1 ..^ 1].toLowerAscii() notin KnownPseudos:
          return ssMatchesNothing
      else:
        let name = part.toLowerAscii()
        if name notin KnownElements:
          return ssMatchesNothing
  ssSupported

proc matchCompound*(compound: seq[string], node: ThemeNode): bool =
  for part in compound:
    if part == "*":
      continue
    if part.startsWith("#"):
      if node.id.toLowerAscii() != part[1 ..^ 1].toLowerAscii():
        return false
    elif part.startsWith("."):
      if part[1 ..^ 1].toLowerAscii() notin node.classes.mapIt(it.toLowerAscii()):
        return false
    elif part.startsWith(":"):
      if part[1 ..^ 1].toLowerAscii() notin node.states.mapIt(it.toLowerAscii()):
        return false
    else:
      ## `body` is the document alias users reach for; the chrome node is
      ## called `window`.
      let want = if part.toLowerAscii() == "body": "window" else: part.toLowerAscii()
      if node.element.toLowerAscii() != want:
        return false
  true

proc matchSelectorAgainst*(compounds: seq[seq[string]], combinators: seq[string],
    node: ThemeNode, ancestors: seq[ThemeNode]): bool =
  ## Right-to-left matching over the ancestor chain: the last compound
  ## matches the node itself, earlier ones match ancestors (` ` anywhere
  ## above, `>` the direct parent).
  if compounds.len == 0 or not matchCompound(compounds[^1], node):
    return false
  var ancestorIdx = ancestors.len - 1
  var compoundIdx = compounds.len - 2
  while compoundIdx >= 0:
    let combinator = combinators[compoundIdx]
    if combinator == ">":
      if ancestorIdx < 0 or not matchCompound(compounds[compoundIdx], ancestors[ancestorIdx]):
        return false
      dec ancestorIdx
    else:
      var found = false
      while ancestorIdx >= 0:
        if matchCompound(compounds[compoundIdx], ancestors[ancestorIdx]):
          found = true
          dec ancestorIdx
          break
        dec ancestorIdx
      if not found:
        return false
    dec compoundIdx
  true

proc compareSpecificity*(a, b: Specificity): int =
  if a.a != b.a: return cmp(a.a, b.a)
  if a.b != b.b: return cmp(a.b, b.b)
  cmp(a.c, b.c)

proc specificityOf*(parts: seq[string]): Specificity =
  for part in parts:
    if part in [">", "+", "~", "||", " ", "*"]:
      continue
    if part.startsWith("#"):
      inc result.a
    elif part.startsWith(".") or part.startsWith(":") or part.startsWith("["):
      inc result.b
    else:
      inc result.c

proc diagnosticToJson*(diagnostic: ThemeDiagnostic): JsonNode =
  %*{
    "selector": diagnostic.selector,
    "property": diagnostic.property,
    "message": diagnostic.message,
    "severity": diagnostic.severity,
    "line": diagnostic.line,
    "col": diagnostic.col
  }

proc parseErrorPosition*(message: string, line: var int, col: var int) =
  ## `CSSParseError` embeds its position as `Error (line:col)`; recover it
  ## for the editor, defaulting to the start when the format ever changes.
  line = 1
  col = 1
  let marker = "Error ("
  let start = message.find(marker)
  if start < 0:
    return
  let rest = message[start + marker.len ..^ 1]
  let colon = rest.find(':')
  let close = rest.find(')')
  if colon < 0 or close < 0 or close < colon:
    return
  try:
    line = parseInt(rest[0 ..< colon])
    col = parseInt(rest[colon + 1 ..< close])
  except ValueError:
    line = 1
    col = 1

proc checkStylesheet*(css: string): tuple[diagnostics: seq[ThemeDiagnostic], rules: int, declarations: int] =
  ## Parses and policy-filters a stylesheet, collecting editor diagnostics.
  ## Never raises for bad input: a syntax error becomes one error
  ## diagnostic, and checking continues nowhere because there is no AST.
  var diagnostics: seq[ThemeDiagnostic] = @[]
  var ruleCount = 0
  var declarationCount = 0
  var style: CssStyleSheet
  try:
    style = parseCss(css, themePolicy())
  except CSSParseError as error:
    var line, col: int
    parseErrorPosition(error.msg, line, col)
    diagnostics.add(ThemeDiagnostic(
      selector: "", property: "",
      message: "Invalid CSS: " & error.msg.splitLines()[^1].strip(),
      severity: "error", line: line, col: col))
    return (diagnostics, 0, 0)
  except CatchableError as error:
    diagnostics.add(ThemeDiagnostic(
      selector: "", property: "",
      message: "Invalid CSS: " & error.msg, severity: "error", line: 1, col: 1))
    return (diagnostics, 0, 0)
  for node in style.nodes:
    case node.kind
    of cssRuleSet:
      inc ruleCount
      for selector in node.selectors:
        let text =
          try: toString(selector)
          except CatchableError: "<selector>"
        case checkSelector(selector)
        of ssUnsupportedCombinator:
          diagnostics.add(ThemeDiagnostic(
            selector: text, property: "",
            message: "Only descendant (space) and child (>) combinators are supported; this selector is skipped.",
            severity: "warning"))
          continue
        of ssUnsupportedFeature:
          diagnostics.add(ThemeDiagnostic(
            selector: text, property: "",
            message: "Attribute selectors and pseudo-elements are not supported; this selector is skipped.",
            severity: "warning"))
          continue
        of ssMatchesNothing:
          diagnostics.add(ThemeDiagnostic(
            selector: text, property: "",
            message: "This selector matches no known interface element and has no effect.",
            severity: "warning"))
        of ssSupported:
          discard
        for decl in node.declarations:
          if decl.kind != cssDeclaration:
            continue
          inc declarationCount
          let property = decl.property.strip().toLowerAscii()
          if not isSupportedProperty(property):
            diagnostics.add(ThemeDiagnostic(
              selector: text, property: decl.property,
              message: "Unsupported property '" & decl.property & "'; supported: " &
                supportedPropertyNames().join(", ") & ".",
              severity: "warning"))
            continue
          if containsBlockedFunction(decl.valueComponents):
            diagnostics.add(ThemeDiagnostic(
              selector: text, property: decl.property,
              message: "url() references are not allowed in themes; this declaration is skipped.",
              severity: "error"))
            continue
          var canonical = ""
          if not canonicalValue(property, decl, canonical):
            diagnostics.add(ThemeDiagnostic(
              selector: text, property: decl.property,
              message: "Invalid value '" & decl.rawValue & "' for " & property & "; this declaration is skipped.",
              severity: "error"))
            continue
    of cssAtRule:
      let name = "@" & node.atName & (if node.prelude.len > 0: " " & node.prelude else: "")
      diagnostics.add(ThemeDiagnostic(
        selector: name, property: "",
        message: "At-rules are not supported in themes; this block is skipped.",
        severity: "warning"))
    of cssComment:
      discard
    else:
      discard
  (diagnostics, ruleCount, declarationCount)

proc collectDeclarations*(css: string, matched: var seq[tuple[selector: CssNode, selectorText: string,
    decl: CssNode, property: string, canonical: string, specificity: Specificity, order: int]]): bool =
  ## Shared parse-and-filter for resolve: appends every usable declaration
  ## with its selector, specificity and source order. Returns false when the
  ## stylesheet does not parse at all.
  var style: CssStyleSheet
  try:
    style = parseCss(css, themePolicy())
  except CatchableError:
    return false
  var order = 0
  for node in style.nodes:
    if node.kind != cssRuleSet:
      continue
    for selector in node.selectors:
      if checkSelector(selector) != ssSupported:
        continue
      let text =
        try: toString(selector)
        except CatchableError: "<selector>"
      for decl in node.declarations:
        if decl.kind != cssDeclaration:
          continue
        inc order
        let property = decl.property.strip().toLowerAscii()
        if not isSupportedProperty(property):
          continue
        if containsBlockedFunction(decl.valueComponents):
          continue
        var canonical = ""
        if not canonicalValue(property, decl, canonical):
          continue
        matched.add((selector, text, decl, property, canonical,
          specificityOf(selector.parts), order))
  true

proc nodeFromJson*(node: JsonNode): ThemeNode =
  result.key = node.getOrDefault("key").getStr("")
  result.element = node.getOrDefault("element").getStr("")
  result.id = node.getOrDefault("id").getStr("")
  if node.hasKey("classes") and node["classes"].kind == JArray:
    for className in node["classes"]:
      result.classes.add(className.getStr(""))
  if node.hasKey("states") and node["states"].kind == JArray:
    for state in node["states"]:
      result.states.add(state.getStr(""))
  if node.hasKey("children") and node["children"].kind == JArray:
    for child in node["children"]:
      result.children.add(nodeFromJson(child))

proc resolveNode*(node: ThemeNode, ancestors: seq[ThemeNode],
    matched: seq[tuple[selector: CssNode, selectorText: string,
      decl: CssNode, property: string, canonical: string,
      specificity: Specificity, order: int]],
    styles: var JsonNode) =
  ## Runs the cascade for one node: every matching declaration contends per
  ## property, and the winner is decided by `!important` first, then
  ## specificity, then source order — the GTK rule.
  var winners = initTable[string, MatchedDeclaration]()
  for entry in matched:
    let (compounds, combinators) = splitCompounds(entry.selector.parts)
    if not matchSelectorAgainst(compounds, combinators, node, ancestors):
      continue
    let candidate = MatchedDeclaration(
      property: entry.property, canonical: entry.canonical,
      important: entry.decl.important, specificity: entry.specificity,
      order: entry.order)
    if entry.property notin winners:
      winners[entry.property] = candidate
    else:
      let current = winners[entry.property]
      var replace = false
      if candidate.important != current.important:
        replace = candidate.important
      elif compareSpecificity(candidate.specificity, current.specificity) != 0:
        replace = compareSpecificity(candidate.specificity, current.specificity) > 0
      else:
        replace = candidate.order > current.order
      if replace:
        winners[entry.property] = candidate
  if winners.len > 0:
    var obj = newJObject()
    for property in winners.keys.toSeq.sorted():
      obj[property] = %winners[property].canonical
    styles[node.key] = obj
  for child in node.children:
    resolveNode(child, ancestors & @[node], matched, styles)

proc specToJson*(): JsonNode =
  ## The supported surface as data: the editor's help text and the Swift
  ## side's instant local feedback read this instead of duplicating the
  ## lists.
  %*{
    "elements": KnownElements,
    "ids": KnownIds,
    "classes": KnownClasses,
    "pseudos": KnownPseudos,
    "properties": {
      "colors": ColorProperties,
      "lengths": LengthProperties,
      "numbers": NumberProperties,
      "gradients": GradientProperties
    }
  }

proc themeCheck*(css: cstring, buffer: ptr char, capacity: int32,
    needed: ptr int32): int32 {.exportc: "bc_theme_check".} =
  ## Parses `css` and reports policy diagnostics as JSON
  ## `{"diagnostics": [...], "rules": n, "declarations": m}`.
  ##
  ## Pure computation, never touches the store, and never fails for bad
  ## input: even a syntax error comes back as `Ok` with one error
  ## diagnostic, because the editor calls this on every keystroke.
  let text = if css.isNil: "" else: $css
  if text.len > MaxCssBytes:
    setError("theme CSS exceeds 256 KiB")
    return ErrBadInput
  let (diagnostics, rules, declarations) = checkStylesheet(text)
  var list = newJArray()
  for diagnostic in diagnostics:
    list.add(diagnosticToJson(diagnostic))
  emitJson(%*{"diagnostics": list, "rules": rules, "declarations": declarations},
    buffer, capacity, needed)

proc themeResolve*(css: cstring, nodesJson: cstring, buffer: ptr char,
    capacity: int32, needed: ptr int32): int32 {.exportc: "bc_theme_resolve".} =
  ## Runs the cascade of `css` over the node tree in `nodesJson`
  ## (`{"nodes": [{key, element, id, classes, states, children}]}`) and
  ## returns `{"styles": {key: {property: canonical-value}}}`.
  ##
  ## Pure computation. Unparseable CSS or node JSON is `ErrBadInput`;
  ## unsupported constructs are skipped silently here (call `bc_theme_check`
  ## for the reasons).
  let text = if css.isNil: "" else: $css
  if text.len > MaxCssBytes:
    setError("theme CSS exceeds 256 KiB")
    return ErrBadInput
  let nodesText = if nodesJson.isNil: "" else: $nodesJson
  if nodesText.len > MaxCssBytes:
    setError("theme node JSON exceeds 256 KiB")
    return ErrBadInput
  var roots: seq[ThemeNode] = @[]
  try:
    let document = parseJson(nodesText)
    if document.kind != JObject or not document.hasKey("nodes") or
        document["nodes"].kind != JArray:
      setError("theme nodes must be {\"nodes\": [...]}")
      return ErrBadInput
    for child in document["nodes"]:
      roots.add(nodeFromJson(child))
  except JsonParsingError as error:
    setError("theme nodes are not valid JSON: " & error.msg)
    return ErrBadInput
  except CatchableError as error:
    setError("theme nodes are not valid: " & error.msg)
    return ErrBadInput
  var matched: seq[tuple[selector: CssNode, selectorText: string,
    decl: CssNode, property: string, canonical: string,
    specificity: Specificity, order: int]] = @[]
  if not collectDeclarations(text, matched):
    setError("theme CSS does not parse")
    return ErrBadInput
  var styles = newJObject()
  for root in roots:
    resolveNode(root, @[], matched, styles)
  emitJson(%*{"styles": styles}, buffer, capacity, needed)

proc themeSerialize*(stylesJson: cstring, buffer: ptr char, capacity: int32,
    needed: ptr int32): int32 {.exportc: "bc_theme_serialize".} =
  ## Prints `{selector: {property: raw-value}}` as canonical CSS — the
  ## managed block the controls regenerate. Values are canonicalized, so a
  ## serialize→parse round-trip is stable by construction; unsupported or
  ## invalid entries are dropped.
  let text = if stylesJson.isNil: "" else: $stylesJson
  if text.len > MaxCssBytes:
    setError("theme styles JSON exceeds 256 KiB")
    return ErrBadInput
  var document: JsonNode
  try:
    document = parseJson(text)
  except JsonParsingError as error:
    setError("theme styles are not valid JSON: " & error.msg)
    return ErrBadInput
  if document.kind != JObject:
    setError("theme styles must be an object")
    return ErrBadInput
  var output = ""
  for selector in document.keys.toSeq.sorted():
    let props = document[selector]
    if props.kind != JObject:
      continue
    var lines: seq[string] = @[]
    for property in props.keys.toSeq.sorted():
      let raw = props[property].getStr("")
      let name = property.strip().toLowerAscii()
      if not isSupportedProperty(name):
        continue
      var mini: CssStyleSheet
      try:
        mini = parseCss(selector & " { " & name & ": " & raw & " }", themePolicy())
      except CatchableError:
        continue
      var canonical = ""
      var kept = false
      for node in mini.nodes:
        if node.kind != cssRuleSet:
          continue
        for sel in node.selectors:
          if checkSelector(sel) != ssSupported:
            continue
        for decl in node.declarations:
          if decl.kind != cssDeclaration:
            continue
          if decl.property.strip().toLowerAscii() != name:
            continue
          if containsBlockedFunction(decl.valueComponents):
            continue
          var value = ""
          if canonicalValue(name, decl, value):
            canonical = value
            kept = true
      if kept:
        lines.add("  " & name & ": " & canonical & ";")
    if lines.len > 0:
      output.add(selector & " {\n" & lines.join("\n") & "\n}\n")
  writeBuffer(output, buffer, capacity, needed)

proc themeSpec*(buffer: ptr char, capacity: int32,
    needed: ptr int32): int32 {.exportc: "bc_theme_spec".} =
  ## The supported surface as JSON (elements, ids, classes, pseudo-classes,
  ## properties): one source of truth for the editor help and Swift-side
  ## instant feedback. Infallible.
  emitJson(specToJson(), buffer, capacity, needed)

proc themeDeclarations*(css: cstring, buffer: ptr char, capacity: int32,
    needed: ptr int32): int32 {.exportc: "bc_theme_declarations".} =
  ## Returns `{"declarations": [{selector, property, value, important,
  ## order}]}` for every supported, valid declaration in source order, with
  ## canonical values. The editor's Apply maps these back onto the
  ## Appearance controls; unsupported or invalid entries are dropped (call
  ## `bc_theme_check` for the reasons). Unparseable CSS is `ErrBadInput`.
  let text = if css.isNil: "" else: $css
  if text.len > MaxCssBytes:
    setError("theme CSS exceeds 256 KiB")
    return ErrBadInput
  var matched: seq[tuple[selector: CssNode, selectorText: string,
    decl: CssNode, property: string, canonical: string,
    specificity: Specificity, order: int]] = @[]
  if not collectDeclarations(text, matched):
    setError("theme CSS does not parse")
    return ErrBadInput
  var list = newJArray()
  for entry in matched:
    list.add(%*{
      "selector": entry.selectorText,
      "property": entry.property,
      "value": entry.canonical,
      "important": entry.decl.important,
      "order": entry.order
    })
  emitJson(%*{"declarations": list}, buffer, capacity, needed)
