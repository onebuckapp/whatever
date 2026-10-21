// Whatever Browser – Made by Humans from OpenPeeps
//
//     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import AppKit
import Foundation
import Highlighter
import Testing
@testable import Whatever

/// Theme value parsing and the editor layer: pure functions over
/// canonical core output and raw text, so no store, engine, or view.
struct ThemeCSSValueTests {
    @Test("six and eight digit hex parse to sRGB")
    func hexColors() {
        let red = ThemeStyleValue.color(["c": "#ff0000"], "c")
        #expect(red?.redComponent == 1)
        #expect(red?.greenComponent == 0)
        #expect(red?.alphaComponent == 1)
        let translucent = ThemeStyleValue.color(["c": "#00ff0080"], "c")
        #expect(abs((translucent?.alphaComponent ?? -1) - 128 / 255) < 0.005)
        #expect(ThemeStyleValue.color(["c": "red"], "c") == nil)
        #expect(ThemeStyleValue.color(["c": "#fff"], "c") == nil)
        #expect(ThemeStyleValue.color([:], "c") == nil)
    }

    @Test("only px lengths parse, opacity clamps")
    func lengthsAndOpacity() {
        #expect(ThemeStyleValue.length(["r": "8px"], "r") == 8)
        #expect(ThemeStyleValue.length(["r": "8"], "r") == nil)
        #expect(ThemeStyleValue.length(["r": "1em"], "r") == nil)
        #expect(ThemeStyleValue.opacity(["o": "0.5"], "o") == 0.5)
        #expect(ThemeStyleValue.opacity(["o": "50%"], "o") == nil)
        #expect(ThemeStyleValue.opacity(["o": "2"], "o") == 1)
        #expect(ThemeStyleValue.opacity(["o": "-1"], "o") == 0)
    }

    @Test("gradients parse direction and stops")
    func gradients() {
        let down = ThemeStyleValue.gradient([
            "background-image": "linear-gradient(to bottom, #ff0000, #0000ff)"
        ])
        #expect(down?.angle == 180)
        #expect(down?.colors.count == 2)
        let corner = ThemeStyleValue.gradient([
            "background-image": "linear-gradient(to bottom right, #ffffff, #000000)"
        ])
        #expect(corner?.angle == 135)
        let degrees = ThemeStyleValue.gradient([
            "background-image": "linear-gradient(45deg, #ffffff, #000000)"
        ])
        #expect(degrees?.angle == 45)
        #expect(ThemeStyleValue.gradient([
            "background-image": "linear-gradient(#ffffff)"
        ]) == nil)
        #expect(ThemeStyleValue.gradient([
            "background-image": "radial-gradient(#ffffff, #000000)"
        ]) == nil)
        #expect(ThemeStyleValue.gradient([:]) == nil)
    }

    @Test("node trees encode for the core")
    func nodeDocument() {
        let tree = [
            ThemeNode(
                key: "window", element: "window",
                children: [ThemeNode(
                    key: "tab:1", element: "tab",
                    classes: ["tab"], states: ["active"])])
        ]
        let text = ThemeNode.document(tree)
        #expect(text?.contains("\"key\":\"tab:1\"") == true)
        #expect(text?.contains("\"states\":[\"active\"]") == true)
        #expect(ThemeNode.document([]) == "{\"nodes\":[]}")
    }

    @Test("managed projection covers the CSS-expressible slice")
    @MainActor
    func managedDocument() {
        let document = ThemeEngine.managedDocument()
        #expect(document[".tab"]?["border-radius"]?.hasSuffix("px") == true)
        #expect(document["#addressbar"]?["border-radius"]?.hasSuffix("px") == true)
        #expect(document["#crawlbar"]?["opacity"] != nil)
        #expect(document["#page"]?["border-radius"]?.hasSuffix("px") == true)
    }
}

/// Highlighting and folding behind the editor: the Highlight.js wrapper
/// and the brace matcher, with no text view involved.
struct ThemeCSSHighlighterTests {
    private func distinctColors(in attributed: NSAttributedString) -> Set<NSColor> {
        var colors = Set<NSColor>()
        attributed.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, _, _ in
            if let color = value as? NSColor {
                colors.insert(color)
            }
        }
        return colors
    }

    @Test("highlighting preserves the text and colors more than one kind")
    func highlightSmoke() {
        guard let highlighter = Highlighter() else {
            Issue.record("Highlighter engine missing (Highlight.min.js or theme)")
            return
        }
        highlighter.setTheme("atom-one-dark")
        let text = ".tab:active {\n  background-color: #1e4fca;\n  opacity: 0.5 !important;\n}"
        guard let highlighted = highlighter.highlight(text, as: "css") else {
            Issue.record("highlight returned nil for CSS")
            return
        }
        #expect(highlighted.string == text)
        #expect(distinctColors(in: highlighted).count >= 2)
    }

    @Test("editor highlighting keeps prior colors when the engine is gone")
    func highlightNilSafety() {
        // ThemeHighlighter.attributed returns nil (never a mismatched
        // string) when the engine cannot answer; the coordinator only
        // applies non-nil results.
        let text = ".tab { color: white; }"
        if let highlighted = ThemeHighlighter.attributed(text) {
            #expect(highlighted.string == text)
        }
    }

    @Test("braces pair into one fold per multi-line rule")
    func foldPairing() {
        let text = "#tabs {\n  color: white;\n}\n.tab {\n  color: black;\n}"
        let folds = CSSFoldScanner.compute(in: text)
        #expect(folds.count == 2)
        #expect(folds[0].startLine == 1)
        #expect(folds[0].endLine == 3)
        #expect(folds[1].startLine == 4)
        #expect(folds[1].endLine == 6)
        // The hidden interior keeps both braces visible.
        #expect((text as NSString).substring(
            with: NSRange(location: folds[0].startOffset, length: 1)) == "{")
        #expect((text as NSString).substring(
            with: NSRange(location: folds[0].endOffset - 1, length: 1)) == "}")
    }

    @Test("braces in strings and comments never fold")
    func foldSkipsLiterals() {
        let text = "/* { */\n.tab::before {\n  content: \"}\";\n}"
        let folds = CSSFoldScanner.compute(in: text)
        #expect(folds.count == 1)
        #expect(folds[0].startLine == 2)
        #expect(folds[0].endLine == 4)
    }

    @Test("single-line rules do not fold")
    func foldSingleLine() {
        #expect(CSSFoldScanner.compute(in: ".tab { color: white; }").isEmpty)
        #expect(CSSFoldScanner.compute(in: "").isEmpty)
    }

    @Test("collapsed folds hide the rule interior only")
    func foldHiddenRanges() {
        var state = CSSFoldState(folds: CSSFoldScanner.compute(
            in: "#a {\n  color: white;\n}"))
        #expect(state.hiddenRanges().isEmpty)
        state.toggle(startOffset: 3)
        // `{` at 3 and `}` at 21 stay visible; 4..<21 hides.
        #expect(state.hiddenRanges() == [NSRange(location: 4, length: 17)])
        #expect(state.markers.map(\.line) == [1])
    }

    @Test("nested folds hide with a collapsed outer")
    func nestedMarkers() {
        var state = CSSFoldState(folds: [
            CSSFold(startOffset: 3, endOffset: 40, startLine: 1, endLine: 5),
            CSSFold(startOffset: 10, endOffset: 30, startLine: 2, endLine: 4),
        ])
        #expect(state.markers.map(\.line) == [1, 2])
        state.toggle(startOffset: 3)
        #expect(state.markers.map(\.line) == [1])
        state.toggle(startOffset: 3)
        #expect(state.markers.map(\.line) == [1, 2])
    }

    @Test("retargeting drops vanished folds")
    func foldRetarget() {
        var state = CSSFoldState(folds: [
            CSSFold(startOffset: 3, endOffset: 13, startLine: 1, endLine: 2),
            CSSFold(startOffset: 30, endOffset: 40, startLine: 4, endLine: 5),
        ])
        state.toggle(startOffset: 3)
        state.toggle(startOffset: 99)
        state.retarget(to: [
            CSSFold(startOffset: 3, endOffset: 13, startLine: 1, endLine: 2),
        ])
        #expect(state.collapsed == [3])
    }

    @Test("typing into a fold unfolds it")
    func foldUnfoldOnType() {
        var state = CSSFoldState(folds: CSSFoldScanner.compute(
            in: "#a {\n  color: white;\n}"))
        state.toggle(startOffset: 3)
        state.unfoldContaining(NSRange(location: 10, length: 0))
        #expect(state.collapsed.isEmpty)
        state.toggle(startOffset: 3)
        state.unfoldContaining(NSRange(location: 0, length: 1))
        #expect(state.collapsed == [3])
    }

    @Test("declaration diagnostics underline the property in its block")
    func diagnosticMapping() {
        let text = "#tabs { color: white; tab-shine: 3; }"
        let diagnostics = [ThemeCSSDiagnostic(
            selector: "#tabs", property: "tab-shine",
            message: "Unsupported", severity: "warning", line: 0, col: 0)]
        let ranges = ThemeCSSDiagnosticRanges.ranges(
            text, diagnostics: diagnostics)
        #expect(ranges.count == 1)
        #expect((text as NSString).substring(with: ranges[0].0) == "tab-shine")
        #expect(ranges[0].1 == "warning")
    }

    @Test("syntax errors underline their line")
    func lineMapping() {
        let text = "#tabs {\n  color: \n}"
        let diagnostics = [ThemeCSSDiagnostic(
            selector: "", property: "",
            message: "Invalid", severity: "error", line: 2, col: 8)]
        let ranges = ThemeCSSDiagnosticRanges.ranges(
            text, diagnostics: diagnostics)
        #expect(ranges.count == 1)
        #expect((text as NSString).substring(with: ranges[0].0) == "  color: ")
        #expect(ranges[0].1 == "error")
    }

    @Test("unknown selectors fall back to no range")
    func missingMapping() {
        let ranges = ThemeCSSDiagnosticRanges.ranges(
            ".tab { color: white; }",
            diagnostics: [ThemeCSSDiagnostic(
                selector: "#nope", property: "color",
                message: "No match", severity: "warning", line: 0, col: 0)])
        #expect(ranges.isEmpty)
    }

    @Test("editor document fills the viewport even when empty")
    @MainActor
    func editorFillsViewport() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let view = NSTextView()
        view.isEditable = true
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        scroll.documentView = view
        let coordinator = ThemeCSSTextView.Coordinator()
        coordinator.view = view
        coordinator.fitHeight()
        // Empty content in a 300pt viewport: the document must still cover
        // it, or clicks land on the clip view and typing goes nowhere.
        #expect(view.isEditable)
        #expect(view.minSize.height == scroll.contentSize.height)
    }
}
