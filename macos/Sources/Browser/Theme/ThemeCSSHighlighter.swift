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
import SwiftUI

/// One policy finding from `bc_theme_check` for underlining.
struct ThemeCSSDiagnostic: Decodable {
    var selector: String
    var property: String
    var message: String
    var severity: String
    var line: Int
    var col: Int

    static func list(from data: Data) -> [ThemeCSSDiagnostic] {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return []
        }
        return document.diagnostics
    }

    private struct Document: Decodable {
        var diagnostics: [ThemeCSSDiagnostic]
    }
}

/// A basic CSS editor: an `NSTextView` with single-pass syntax coloring and
/// policy-diagnostic underlines. SwiftUI's `TextEditor` cannot style ranges,
/// so this wraps AppKit directly.
///
/// Coloring is deliberately shallow — comments, strings, selectors by kind,
/// properties, values by shape, `!important` — over the whole document on a
/// short debounce. Theme stylesheets are small; no incremental machinery.
struct ThemeCSSTextView: NSViewRepresentable {
    @Binding var text: String
    var diagnostics: [ThemeCSSDiagnostic]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let view = NSTextView()
        view.isRichText = true
        view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.allowsUndo = true
        view.isEditable = true
        view.isSelectable = true
        // The classic programmatic recipe: without it the document view keeps
        // its zero frame inside the clip view, painting background but never
        // taking focus — an editor that looks present and accepts no typing.
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.font = Self.baseFont
        view.textColor = NSColor.textColor
        view.backgroundColor = NSColor.textBackgroundColor
        view.delegate = context.coordinator
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.parent = self
        view.string = text
        context.coordinator.highlight()
        // Fires on scroll and resize, which do not always re-run
        // `updateNSView`: the document keeps filling the viewport.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let view = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if view.string != text {
            view.string = text
        }
        context.coordinator.fitHeight()
        context.coordinator.highlight()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static var baseFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var view: NSTextView?
        var parent: ThemeCSSTextView?
        private var pending: DispatchWorkItem?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func clipBoundsChanged(_ note: Notification) {
            fitHeight()
        }

        func textDidChange(_ notification: Notification) {
            guard let view, let parent else { return }
            parent.text = view.string
            scheduleHighlight()
        }

        func scheduleHighlight() {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlight() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        /// Pins the document height to at least the visible height. A
        /// vertically-resizable text view sizes to its content, so an empty
        /// editor collapses to one line inside a tall scroll area and every
        /// click below that line lands on the clip view — an editor that
        /// looks present and accepts no typing.
        func fitHeight() {
            guard let view, let scroll = view.enclosingScrollView else { return }
            let height = max(scroll.contentSize.height, 180)
            if view.minSize.height != height {
                view.minSize = NSSize(width: 0, height: height)
            }
        }

        func highlight() {
            guard let view, let parent else { return }
            let text = view.string
            let storage = view.textStorage
            guard let storage else { return }
            storage.beginEditing()
            let full = NSRange(location: 0, length: (text as NSString).length)
            storage.removeAttribute(.foregroundColor, range: full)
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.underlineColor, range: full)
            storage.addAttribute(.font, value: ThemeCSSTextView.baseFont, range: full)
            for (range, color) in ThemeCSSScanner.colorize(text) {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            for (range, severity) in ThemeCSSScanner.diagnosticRanges(
                text, diagnostics: parent.diagnostics)
            {
                storage.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range)
                storage.addAttribute(
                    .underlineColor,
                    value: severity == "error" ? NSColor.systemRed : NSColor.systemOrange,
                    range: range)
            }
            storage.endEditing()
        }
    }
}

// MARK: - Scanner

/// The pure scanner behind the editor: token colors and diagnostic ranges
/// over raw text, with no text view involved. Separate from the MainActor
/// coordinator so tests (and any background use) call it freely.
enum ThemeCSSScanner {
    private struct Colors {
        static let element = NSColor.textColor
        static let id = NSColor.systemTeal
        static let className = NSColor.systemOrange
        static let pseudo = NSColor.systemPurple
        static let combinator = NSColor.secondaryLabelColor
        static let property = NSColor.systemRed
        static let value = NSColor.textColor
        static let number = NSColor.systemBlue
        static let function = NSColor.systemGreen
        static let important = NSColor.systemPink
        static let string = NSColor.systemBrown
        static let comment = NSColor.secondaryLabelColor
        static let atRule = NSColor.systemGray
        static let punctuation = NSColor.secondaryLabelColor
    }

    /// Single-pass scan yielding colored ranges. Tracks brace depth so
    /// selector position and declaration position colorize differently, and
    /// skips comments and strings structurally rather than by pattern.
    static func colorize(_ text: String) -> [(NSRange, NSColor)] {
        var marks: [(NSRange, NSColor)] = []
        let chars = Array(text)
        var i = 0
        var depth = 0

        func mark(_ start: Int, _ end: Int, _ color: NSColor) {
            guard end > start else { return }
            marks.append((
                NSRange(location: start, length: end - start), color))
        }
        func isIdent(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "-" || c == "_"
        }

        while i < chars.count {
            let c = chars[i]
            // Comments win everywhere.
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") {
                    j += 1
                }
                j = min(j + 2, chars.count)
                mark(i, j, Colors.comment)
                i = j
                continue
            }
            // Strings win everywhere.
            if c == "\"" || c == "'" {
                let quote = c
                var j = i + 1
                while j < chars.count, chars[j] != quote {
                    if chars[j] == "\\" { j += 1 }
                    j += 1
                }
                j = min(j + 1, chars.count)
                mark(i, j, Colors.string)
                i = j
                continue
            }
            if depth == 0 {
                switch c {
                case "{":
                    mark(i, i + 1, Colors.punctuation)
                    depth += 1
                    i += 1
                case "}":
                    mark(i, i + 1, Colors.punctuation)
                    i += 1
                case "#":
                    var j = i + 1
                    while j < chars.count, isIdent(chars[j]) { j += 1 }
                    mark(i, j, Colors.id)
                    i = j
                case ".":
                    var j = i + 1
                    while j < chars.count, isIdent(chars[j]) { j += 1 }
                    mark(i, j, Colors.className)
                    i = j
                case ":":
                    var j = i + 1
                    if j < chars.count, chars[j] == ":" { j += 1 }
                    while j < chars.count, isIdent(chars[j]) { j += 1 }
                    if j < chars.count, chars[j] == "(" {
                        var k = j + 1
                        var parens = 1
                        while k < chars.count, parens > 0 {
                            if chars[k] == "(" { parens += 1 }
                            if chars[k] == ")" { parens -= 1 }
                            k += 1
                        }
                        j = k
                    }
                    mark(i, j, Colors.pseudo)
                    i = j
                case "@":
                    var j = i + 1
                    while j < chars.count, isIdent(chars[j]) { j += 1 }
                    mark(i, j, Colors.atRule)
                    i = j
                case ",", ">", "+", "~", "*", "[", "]", "=", "|", "^", "$":
                    mark(i, i + 1, Colors.combinator)
                    i += 1
                default:
                    if isIdent(c) {
                        var j = i
                        while j < chars.count, isIdent(chars[j]) { j += 1 }
                        mark(i, j, Colors.element)
                        i = j
                    } else {
                        i += 1
                    }
                }
            } else {
                // Inside a block: properties, values, and structure.
                switch c {
                case "{":
                    mark(i, i + 1, Colors.punctuation)
                    depth += 1
                    i += 1
                case "}":
                    mark(i, i + 1, Colors.punctuation)
                    depth = max(0, depth - 1)
                    i += 1
                case "#":
                    var j = i + 1
                    while j < chars.count, isIdent(chars[j]) { j += 1 }
                    mark(i, j, Colors.value)
                    i = j
                case "!":
                    let word = String(chars[i...min(i + 9, chars.count - 1)])
                    if word.hasPrefix("!important") {
                        mark(i, i + 10, Colors.important)
                        i += 10
                    } else {
                        i += 1
                    }
                case ";", ":", "(", ")", ",":
                    mark(i, i + 1, Colors.punctuation)
                    i += 1
                case "@":
                    var j = i + 1
                    while j < chars.count, isIdent(chars[j]) { j += 1 }
                    mark(i, j, Colors.atRule)
                    i = j
                default:
                    if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                        var j = i
                        while j < chars.count,
                              chars[j].isNumber || chars[j] == "." || chars[j] == "%"
                        { j += 1 }
                        while j < chars.count, isIdent(chars[j]) { j += 1 }
                        mark(i, j, Colors.number)
                        i = j
                    } else if isIdent(c) {
                        var j = i
                        while j < chars.count, isIdent(chars[j]) { j += 1 }
                        // Look ahead: `name:` at value start is a property;
                        // `name(` is a function; otherwise a value word.
                        var k = j
                        while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                        if k < chars.count, chars[k] == ":" {
                            mark(i, j, Colors.property)
                        } else if k < chars.count, chars[k] == "(" {
                            var m = k + 1
                            var parens = 1
                            while m < chars.count, parens > 0 {
                                if chars[m] == "(" { parens += 1 }
                                if chars[m] == ")" { parens -= 1 }
                                m += 1
                            }
                            mark(i, m, Colors.function)
                            j = m
                        } else {
                            mark(i, j, Colors.value)
                        }
                        i = j
                    } else {
                        i += 1
                    }
                }
            }
        }
        return marks
    }

    /// Maps policy diagnostics back to text ranges: syntax errors underline
    /// their line, declaration findings underline the property inside its
    /// selector's block.
    static func diagnosticRanges(
        _ text: String, diagnostics: [ThemeCSSDiagnostic]
    ) -> [(NSRange, String)] {
        var ranges: [(NSRange, String)] = []
        let ns = text as NSString
        for diagnostic in diagnostics {
            if diagnostic.selector.isEmpty {
                if diagnostic.line > 0 {
                    let lines = text.components(separatedBy: "\n")
                    if diagnostic.line <= lines.count {
                        var location = 0
                        for index in 0 ..< diagnostic.line - 1 {
                            location += lines[index].utf16.count + 1
                        }
                        let length = lines[diagnostic.line - 1].utf16.count
                        if location + length <= ns.length {
                            ranges.append((
                                NSRange(location: location, length: max(length, 1)),
                                diagnostic.severity))
                        }
                    }
                }
                continue
            }
            let hit = ns.range(of: diagnostic.selector, options: .literal)
            guard hit.location != NSNotFound else { continue }
            let selectorRange = hit
            if diagnostic.property.isEmpty {
                ranges.append((selectorRange, diagnostic.severity))
                continue
            }
            let blockEnd = ns.range(
                of: "}", options: .literal,
                range: NSRange(
                    location: selectorRange.upperBound,
                    length: ns.length - selectorRange.upperBound))
            let limit = blockEnd.location == NSNotFound
                ? ns.length : blockEnd.location
            let propHit = ns.range(
                of: diagnostic.property, options: .literal,
                range: NSRange(
                    location: selectorRange.upperBound,
                    length: max(0, limit - selectorRange.upperBound)))
            if propHit.location != NSNotFound {
                ranges.append((propHit, diagnostic.severity))
            } else {
                ranges.append((selectorRange, diagnostic.severity))
            }
        }
        return ranges
    }
}
