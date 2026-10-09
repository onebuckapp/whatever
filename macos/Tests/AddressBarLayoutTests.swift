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
import Testing
@testable import Whatever

/// Proves the toolbar strip's width modes with the real view classes: a
/// centred fixed field by default, and a field stretched between the button
/// clusters that re-resolves on resize. Headless-safe: Auto Layout solves
/// without a window.
@MainActor
struct AddressBarLayoutTests {
    /// Mirrors `configureAddressField` + `configureCenterStack`: a container
    /// with a preferred width, a required cap, and a fill-distribution stack.
    private func makeStrip(feedHidden: Bool = true) -> (
        toolbar: BrowserToolbarView,
        stack: NSStackView,
        container: NSView,
        maxWidth: NSLayoutConstraint,
        preferredWidth: NSLayoutConstraint
    ) {
        let leading = (0..<3).map { _ in BrowserToolbarButton(frame: .zero) }
        let trailing = (0..<4).map { _ in BrowserToolbarButton(frame: .zero) }
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let feed = BrowserToolbarButton(frame: .zero)
        feed.isHidden = feedHidden
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.distribution = .fill
        stack.addArrangedSubview(container)
        stack.addArrangedSubview(feed)
        let toolbar = BrowserToolbarView(leading: leading, center: stack, trailing: trailing)
        let preferred = container.widthAnchor.constraint(equalToConstant: 460)
        preferred.priority = .defaultHigh
        let maxWidth = container.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        let height = container.heightAnchor.constraint(equalToConstant: 32)
        NSLayoutConstraint.activate([preferred, maxWidth, height])
        return (toolbar, stack, container, maxWidth, preferred)
    }

    private func layout(_ toolbar: BrowserToolbarView, width: CGFloat) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 52))
        host.addSubview(toolbar)
        toolbar.frame = host.bounds
        toolbar.autoresizingMask = [.width, .height]
        host.layoutSubtreeIfNeeded()
    }

    @Test("centred mode keeps a fixed field in the middle")
    @MainActor
    func centredMode() {
        let strip = makeStrip()
        layout(strip.toolbar, width: 1200)
        #expect(abs(strip.stack.frame.width - 460) < 1, "stack is \(strip.stack.frame.width)pt, want 460")
        #expect(abs(strip.stack.frame.midX - 600) < 1, "stack not centred")
        #expect(abs(strip.container.frame.width - 460) < 1, "container not 460")
    }

    @Test("stretch mode fills between the clusters")
    @MainActor
    func stretchMode() {
        let strip = makeStrip()
        strip.maxWidth.isActive = false
        strip.preferredWidth.isActive = false
        strip.toolbar.setFullWidth(true)
        layout(strip.toolbar, width: 1200)
        // 1200 - 92 (window buttons) - 94 (3 leading) - 8 - 8 (gaps)
        // - 126 (4 trailing) - 10 (trailing inset).
        #expect(abs(strip.stack.frame.width - 862) < 1, "stack is \(strip.stack.frame.width)pt, want 862")
        #expect(abs(strip.container.frame.width - strip.stack.frame.width) < 1,
                "container \(strip.container.frame.width)pt did not fill the \(strip.stack.frame.width)pt stack")
    }

    @Test("stretch mode re-resolves on resize")
    @MainActor
    func stretchResizes() {
        let strip = makeStrip()
        strip.maxWidth.isActive = false
        strip.preferredWidth.isActive = false
        strip.toolbar.setFullWidth(true)
        layout(strip.toolbar, width: 1200)
        let wide = strip.stack.frame.width
        layout(strip.toolbar, width: 900)
        #expect(abs(strip.stack.frame.width - (wide - 300)) < 1,
                "stack did not shrink with the window: \(strip.stack.frame.width)pt")
    }

    @Test("typing leaves the stretched field and its chrome unmoved")
    func typingKeepsStretch() {
        // Faithful replica: a plain container holding the real field, pinned
        // exactly like `configureAddressField` pins them.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let field = SpotlightField(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 32),
        ])
        let preferred = container.widthAnchor.constraint(equalToConstant: 460)
        preferred.priority = .defaultHigh
        let maxWidth = container.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        let height = container.heightAnchor.constraint(equalToConstant: 32)
        NSLayoutConstraint.activate([preferred, maxWidth, height])

        let leading = (0..<3).map { _ in BrowserToolbarButton(frame: .zero) }
        let trailing = (0..<4).map { _ in BrowserToolbarButton(frame: .zero) }
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.distribution = .fill
        stack.addArrangedSubview(container)
        let toolbar = BrowserToolbarView(leading: leading, center: stack, trailing: trailing)
        maxWidth.isActive = false
        preferred.isActive = false
        toolbar.setFullWidth(true)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 52))
        host.addSubview(toolbar)
        toolbar.frame = host.bounds
        toolbar.autoresizingMask = [.width, .height]
        host.layoutSubtreeIfNeeded()
        let idleContainer = container.frame
        let idleField = field.frame
        #expect(abs(idleContainer.width - 862) < 2, "setup did not stretch: \(idleContainer)")

        // Type: text appears, the clear button shows, the dropdown opens.
        field.textField.stringValue = "hello world example.com"
        field.updateClearButton()
        field.isOpen = true
        host.layoutSubtreeIfNeeded()
        #expect(abs(container.frame.width - idleContainer.width) < 0.5,
                "typing resized the container: \(idleContainer) -> \(container.frame)")
        #expect(abs(container.frame.minX - idleContainer.minX) < 0.5,
                "typing moved the container: \(idleContainer) -> \(container.frame)")
        #expect(abs(field.frame.width - idleField.width) < 0.5,
                "typing resized the field: \(idleField) -> \(field.frame)")
    }

    @Test("dropdown keeps field width no matter the rows")
    func dropdownFollowsFieldWidth() {
        let field = SpotlightField(frame: NSRect(x: 194, y: 10, width: 862, height: 32))
        field.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 200))
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 194),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -144),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            field.heightAnchor.constraint(equalToConstant: 32),
        ])
        // Same arrangement as `panel()`: leading pin plus an explicit width
        // synced from the field — never a trailing pin the content could
        // fight the bar through.
        let dropdown = SpotlightDropdown()
        dropdown.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dropdown)
        NSLayoutConstraint.activate([
            dropdown.topAnchor.constraint(equalTo: field.bottomAnchor, constant: -1),
            dropdown.leadingAnchor.constraint(equalTo: field.leadingAnchor),
        ])
        let width = dropdown.widthAnchor.constraint(equalToConstant: field.frame.width)
        width.isActive = true
        container.layoutSubtreeIfNeeded()
        #expect(abs(dropdown.frame.width - field.frame.width) < 0.5,
                "dropdown \(dropdown.frame) does not match field \(field.frame)")

        // With results: six screenshot-length rows must not move or resize
        // either the panel or the field it hangs from.
        let titles = [
            "Digi Live - live TV Digi24 si Digi locale, TV online | Digi24",
            "Digi Sport - stiri din sport, meciuri live - Spectacolul campionilor",
            "Digi24 - Stiri - Informatia la putere intotdeauna si oriunde",
            "404 - Pagina nu a fost gasita nicaieri pe acest website",
            "Atac sangeros intr-o scoala din Polonia: cel putin sapte morti",
            "Vremea in Bucuresti astazi: temperaturi record pentru octombrie",
        ]
        var rows: [String] = []
        for (index, title) in titles.enumerated() {
            rows.append(
                "{\"id\":\"\(index)\",\"url\":\"https://www.digi24.ro/stiri/\(index)/un-titlu-foarte-lung-care-continua\",\"title\":\"\(title)\",\"host\":\"www.digi24.ro\",\"firstVisited\":1700000000,\"lastVisited\":1700000100,\"visitCount\":3,\"score\":1.5,\"titlePositions\":[0],\"urlPositions\":[]}"
            )
        }
        let data = ("[" + rows.joined(separator: ",") + "]").data(using: .utf8)!
        dropdown.setResults(
            HistoryFuzzyEntry.decodeList(data),
            selectedID: nil,
            scrollToSelection: false,
            onHover: { _ in },
            onChoose: { _ in }
        )
        width.constant = field.frame.width
        container.layoutSubtreeIfNeeded()
        #expect(abs(dropdown.frame.width - 862) < 0.5,
                "dropdown with results \(dropdown.frame) lost the field width")
        #expect(abs(field.frame.width - 862) < 0.5,
                "results resized the field: \(field.frame)")
    }
}
