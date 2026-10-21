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
import Highlighter
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

// MARK: - Highlighting

/// The shared Highlight.js wrapper, configured once for the editor: a dark
/// theme (only its foreground colors are ever read) and the editor's own
/// monospaced font. In-process and synchronous, so highlighting never
/// crosses XPC — the round trip that left the editor black stays reserved
/// for policy diagnostics, which genuinely live in the core.
enum ThemeHighlighter {
    static var shared: Highlighter? = {
        guard let highlighter = Highlighter() else { return nil }
        highlighter.setTheme("atom-one-dark")
        highlighter.theme.setCodeFont(ThemeCSSTextView.baseFont)
        return highlighter
    }()

    /// The editor text colored as CSS, or nil when the engine is missing
    /// or disagrees about the characters. Callers keep the previous
    /// colors on nil: an uncolored keystroke beats a blank editor.
    static func attributed(_ text: String) -> NSAttributedString? {
        guard !text.isEmpty,
              let highlighted = shared?.highlight(text, as: "css"),
              highlighted.string == text
        else { return nil }
        return highlighted
    }
}

// MARK: - Folds

/// One multi-line `{ … }` span: UTF-16 offsets straight into the editor
/// text (no byte conversion — computed locally), with 1-based lines for
/// the gutter.
struct CSSFold: Equatable, Sendable {
    /// Offset of `{`.
    var startOffset: Int
    /// Exclusive end, just past `}`.
    var endOffset: Int
    var startLine: Int
    var endLine: Int
}

/// Brace matching over raw text, blind to braces inside strings and
/// comments. Single-line rules never fold. Pure, so tests drive it
/// without a text view.
enum CSSFoldScanner {
    static func compute(in text: String) -> [CSSFold] {
        let units = Array(text.utf16)
        var folds: [CSSFold] = []
        // (offset of `{`, its line).
        var stack: [(Int, Int)] = []
        var line = 1
        var i = 0
        while i < units.count {
            let unit = units[i]
            switch unit {
            case 0x0A: // \n
                line += 1
                i += 1
            case 0x2F where i + 1 < units.count && units[i + 1] == 0x2A: // /*
                var j = i + 2
                while j + 1 < units.count, !(units[j] == 0x2A && units[j + 1] == 0x2F) {
                    if units[j] == 0x0A { line += 1 }
                    j += 1
                }
                i = min(j + 2, units.count)
            case 0x22, 0x27: // " '
                let quote = unit
                var j = i + 1
                while j < units.count, units[j] != quote {
                    if units[j] == 0x5C { j += 1 } // backslash escapes the next unit
                    if units[j] == 0x0A { line += 1 }
                    j += 1
                }
                i = min(j + 1, units.count)
            case 0x7B: // {
                stack.append((i, line))
                i += 1
            case 0x7D: // }
                if let (openOffset, openLine) = stack.popLast(), line > openLine {
                    folds.append(CSSFold(
                        startOffset: openOffset, endOffset: i + 1,
                        startLine: openLine, endLine: line))
                }
                i += 1
            default:
                i += 1
            }
        }
        return folds.sorted { $0.startOffset < $1.startOffset }
    }
}

/// Which folds are collapsed, keyed by start offset (stable while typing
/// elsewhere in the document). Pure: the coordinator owns one and
/// re-targets it on every highlight.
struct CSSFoldState {
    var folds: [CSSFold] = []
    var collapsed: Set<Int> = []

    mutating func retarget(to folds: [CSSFold]) {
        self.folds = folds
        let starts = Set(folds.map(\.startOffset))
        collapsed = collapsed.intersection(starts)
    }

    mutating func toggle(startOffset: Int) {
        if collapsed.contains(startOffset) {
            collapsed.remove(startOffset)
        } else {
            collapsed.insert(startOffset)
        }
    }

    /// Unfolds every collapsed fold whose hidden interior intersects
    /// `range`: typing into a folded region reveals it as you type. A
    /// caret is zero-length, so containment (not intersection) decides
    /// for it.
    mutating func unfoldContaining(_ range: NSRange) {
        for offset in collapsed {
            guard let fold = folds.first(where: { $0.startOffset == offset }) else { continue }
            let hidden = NSRange(
                location: fold.startOffset + 1,
                length: max(0, fold.endOffset - fold.startOffset - 2))
            let hit =
                range.length == 0
                ? NSLocationInRange(range.location, hidden)
                : NSIntersectionRange(hidden, range).length > 0
            if hit {
                collapsed.remove(offset)
            }
        }
    }

    /// Character ranges hidden by collapsed folds: the rule interior
    /// between the braces, keeping `{` and `}` on their lines.
    func hiddenRanges() -> [NSRange] {
        var out: [NSRange] = []
        for offset in collapsed {
            guard let fold = folds.first(where: { $0.startOffset == offset }) else { continue }
            let length = fold.endOffset - fold.startOffset - 2
            guard length > 0 else { continue }
            out.append(NSRange(location: fold.startOffset + 1, length: length))
        }
        return out.sorted { $0.location < $1.location }
    }

    /// Chevron rows: 1-based start lines of folds, skipping folds nested
    /// inside a collapsed outer (their lines are hidden with it).
    var markers: [(line: Int, startOffset: Int, collapsed: Bool)] {
        folds.compactMap { fold in
            for offset in collapsed {
                guard let outer = folds.first(where: { $0.startOffset == offset }) else { continue }
                if outer.startLine < fold.startLine, fold.startLine < outer.endLine {
                    return nil
                }
            }
            return (fold.startLine, fold.startOffset, collapsed.contains(fold.startOffset))
        }
    }
}

/// Maps policy diagnostics back to text ranges: syntax errors underline
/// their line, declaration findings underline the property inside its
/// selector's block.
enum ThemeCSSDiagnosticRanges {
    static func ranges(
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

// MARK: - Editor view

/// The Custom CSS editor: one `NSTextView` that mimics a textarea, with
/// Highlight.js token colors, policy-diagnostic underlines, and a fold
/// gutter with chevrons. SwiftUI's `TextEditor` cannot style ranges, so
/// this wraps AppKit directly.
///
/// The text itself is never rewritten for display — colors apply as
/// attributes and folding hides glyphs — so model and view offsets stay
/// identical and diagnostics map without translation.
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
        // Gutter room: the fold chevrons live in this strip.
        view.textContainerInset = NSSize(width: 16, height: 0)
        view.font = Self.baseFont
        view.textColor = NSColor.textColor
        view.backgroundColor = NSColor.textBackgroundColor
        view.delegate = context.coordinator
        view.layoutManager?.delegate = context.coordinator
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.parent = self
        let gutter = CSSFoldGutterView()
        gutter.onToggle = { [weak coordinator = context.coordinator] offset in
            coordinator?.toggleFold(startOffset: offset)
        }
        scroll.contentView.addSubview(gutter)
        context.coordinator.gutter = gutter
        view.string = text
        context.coordinator.highlight()
        // Fires on scroll and resize, which do not always re-run
        // `updateNSView`: the document keeps filling the viewport, and the
        // gutter keeps tracking the visible lines.
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
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        weak var view: NSTextView?
        weak var gutter: CSSFoldGutterView?
        var parent: ThemeCSSTextView?
        private var pending: DispatchWorkItem?
        private var foldState = CSSFoldState()
        private var hiddenCharRanges: [NSRange] = []

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func clipBoundsChanged(_ note: Notification) {
            fitHeight()
            layoutGutter()
        }

        func textDidChange(_ notification: Notification) {
            guard let view, let parent else { return }
            parent.text = view.string
            unfoldCaret()
            scheduleHighlight()
        }

        func toggleFold(startOffset: Int) {
            foldState.toggle(startOffset: startOffset)
            refreshFolds()
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
            // Only the foreground colors travel: the theme's font, paragraph
            // style, and background stay behind, so the editor keeps its own
            // look and a failed highlight keeps the previous colors.
            if let highlighted = ThemeHighlighter.attributed(text) {
                highlighted.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                    if let color = attrs[.foregroundColor] as? NSColor {
                        storage.addAttribute(.foregroundColor, value: color, range: range)
                    }
                }
            }
            for (range, severity) in ThemeCSSDiagnosticRanges.ranges(
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
            refreshFolds()
        }

        /// Typing into a folded region unfolds it: the caret's new home is
        /// hidden otherwise, and revealing as you type is the honest answer.
        private func unfoldCaret() {
            guard let view, !foldState.collapsed.isEmpty else { return }
            let before = foldState.collapsed
            foldState.unfoldContaining(view.selectedRange())
            if foldState.collapsed != before {
                refreshFolds()
            }
        }

        private func refreshFolds() {
            guard let view, let manager = view.layoutManager else { return }
            foldState.retarget(to: CSSFoldScanner.compute(in: view.string))
            let hidden = foldState.hiddenRanges()
            if hidden != hiddenCharRanges {
                hiddenCharRanges = hidden
                let full = NSRange(location: 0, length: (view.string as NSString).length)
                manager.invalidateGlyphs(
                    forCharacterRange: full, changeInLength: 0,
                    actualCharacterRange: nil)
                manager.invalidateLayout(
                    forCharacterRange: full, actualCharacterRange: nil)
            }
            layoutGutter()
        }

        /// Pins the gutter to the visible strip and rebuilds its chevrons
        /// from the current layout.
        private func layoutGutter() {
            guard let view, let gutter, let clip = view.enclosingScrollView?.contentView,
                  let manager = view.layoutManager
            else { return }
            let visible = clip.bounds
            gutter.frame = NSRect(x: 0, y: visible.origin.y, width: 16, height: visible.height)
            let ns = view.string as NSString
            var lineStarts: [Int] = []
            var location = 0
            while location < ns.length {
                lineStarts.append(location)
                location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            }
            var markers: [(y: CGFloat, startOffset: Int, collapsed: Bool)] = []
            for marker in foldState.markers {
                guard marker.line >= 1, marker.line <= lineStarts.count else { continue }
                let glyph = manager.glyphIndexForCharacter(at: lineStarts[marker.line - 1])
                let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                guard rect.height > 0 else { continue }
                markers.append((
                    y: rect.midY - visible.origin.y,
                    startOffset: marker.startOffset,
                    collapsed: marker.collapsed))
            }
            gutter.markers = markers
        }

        // MARK: - Folding via the layout manager

        private func hiddenContains(_ charIndex: Int) -> Bool {
            hiddenCharRanges.contains {
                charIndex >= $0.location && charIndex < $0.upperBound
            }
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<NSGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font aFont: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            let count = glyphRange.length
            guard count > 0 else { return 0 }
            // CGGlyph is 16 bits against NSGlyph's 32: a rebind would
            // corrupt the stride, so substitute into a sibling buffer and
            // convert. Untouched ranges pass through `setGlyphs` unchanged:
            // the delegate owns generation once implemented, and the
            // header blesses this call only from here.
            var converted = [CGGlyph](repeating: 0, count: count)
            for i in 0 ..< count {
                if hiddenContains(charIndexes[i]) {
                    converted[i] = CGGlyph(NSNullGlyph)
                } else {
                    converted[i] = CGGlyph(truncatingIfNeeded: glyphs[i])
                }
            }
            converted.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                layoutManager.setGlyphs(
                    base, properties: props,
                    characterIndexes: charIndexes,
                    font: aFont, forGlyphRange: glyphRange)
            }
            return count
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            usedRect lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            guard !hiddenCharRanges.isEmpty else { return false }
            let charRange = layoutManager.characterRange(
                forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.length > 0 else { return false }
            let fullyHidden = hiddenCharRanges.contains {
                charRange.location >= $0.location
                    && charRange.upperBound <= $0.upperBound
            }
            guard fullyHidden else { return false }
            lineFragmentRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.origin.y = lineFragmentRect.pointee.origin.y
            baselineOffset.pointee = 0
            return true
        }
    }
}

// MARK: - Fold gutter

/// The fold chevron strip: a transparent overlay pinned to the visible
/// left edge (the text starts right of it via `textContainerInset`), so
/// no ruler coordinates are ever needed. Chevron right means collapsed,
/// down means expanded; misses do nothing.
final class CSSFoldGutterView: NSView {
    var markers: [(y: CGFloat, startOffset: Int, collapsed: Bool)] = [] {
        didSet {
            guard markers.map(\.y) != oldValue.map(\.y)
                    || markers.map(\.collapsed) != oldValue.map(\.collapsed)
            else { return }
            needsDisplay = true
        }
    }

    var onToggle: ((Int) -> Void)?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        for marker in markers {
            let center = NSPoint(x: 8, y: marker.y)
            let path = NSBezierPath()
            if marker.collapsed {
                path.move(to: NSPoint(x: center.x - 2.5, y: center.y - 4))
                path.line(to: NSPoint(x: center.x + 3.5, y: center.y))
                path.line(to: NSPoint(x: center.x - 2.5, y: center.y + 4))
            } else {
                path.move(to: NSPoint(x: center.x - 4, y: center.y + 2.5))
                path.line(to: NSPoint(x: center.x + 4, y: center.y + 2.5))
                path.line(to: NSPoint(x: center.x, y: center.y - 3.5))
            }
            path.close()
            path.lineWidth = 1.4
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = markers.min(by: {
            abs($0.y - point.y) < abs($1.y - point.y)
        }), abs(hit.y - point.y) <= 9 {
            onToggle?(hit.startOffset)
        }
    }
}
