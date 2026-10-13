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
import Testing
@testable import Whatever

/// Theme value parsing and the highlighter scanner: pure functions over
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

/// The scanner behind the editor: token colors and diagnostic underlines
/// over raw text, with no text view involved.
struct ThemeCSSHighlighterTests {
    private func color(
        _ marks: [(NSRange, NSColor)], at location: Int
    ) -> NSColor? {
        marks.first { NSLocationInRange(location, $0.0) }?.1
    }

    @Test("selectors, properties, and values colorize by kind")
    func tokenKinds() {
        let text = ".tab:active { color: #fff; opacity: 0.5 !important; }"
        let marks = ThemeCSSScanner.colorize(text)
        // `.tab` class, `:active` pseudo, `color` property, `#fff` value,
        // `0.5` number, `!important` flag each carry a color.
        #expect(color(marks, at: 0) == NSColor.systemOrange)
        #expect(color(marks, at: 4) == NSColor.systemPurple)
        #expect(color(marks, at: 14) == NSColor.systemRed)
        #expect(color(marks, at: 21) != nil)
        #expect(color(marks, at: 36) == NSColor.systemBlue)
        #expect(color(marks, at: 40) == NSColor.systemPink)
    }

    @Test("comments and strings win over structure")
    func commentsAndStrings() {
        let text = "/* .tab { */ .tab { color: \"red;\"; }"
        let marks = ThemeCSSScanner.colorize(text)
        #expect(color(marks, at: 3) == NSColor.secondaryLabelColor)
        #expect(color(marks, at: 14) == NSColor.systemOrange)
        #expect(color(marks, at: 28) == NSColor.systemBrown)
    }

    @Test("declaration diagnostics underline the property in its block")
    func diagnosticMapping() {
        let text = "#tabs { color: white; tab-shine: 3; }"
        let diagnostics = [ThemeCSSDiagnostic(
            selector: "#tabs", property: "tab-shine",
            message: "Unsupported", severity: "warning", line: 0, col: 0)]
        let ranges = ThemeCSSScanner.diagnosticRanges(
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
        let ranges = ThemeCSSScanner.diagnosticRanges(
            text, diagnostics: diagnostics)
        #expect(ranges.count == 1)
        #expect((text as NSString).substring(with: ranges[0].0) == "  color: ")
        #expect(ranges[0].1 == "error")
    }

    @Test("unknown selectors fall back to no range")
    func missingMapping() {
        let ranges = ThemeCSSScanner.diagnosticRanges(
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
