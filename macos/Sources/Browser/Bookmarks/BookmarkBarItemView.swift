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

/// One entry on the bookmarks bar: a text button that opens a link or a
/// folder's menu, with the chrome's usual hover-only fill.
@MainActor
final class BookmarkBarItemView: NSButton {
    /// The entry this button shows. Read by the bar's callbacks.
    let node: BookmarkNode

    var onActivate: (() -> Void)?
    var onMiddleClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    /// Highlighted while a dragged bookmark hovers to be filed into this
    /// folder.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            needsDisplay = true
        }
    }

    private static let fillRadius: CGFloat = 6
    private static let hoverAlpha: CGFloat = 0.06
    private static let pressedAlpha: CGFloat = 0.12
    /// Past this many points the press was a drag, not a click.
    private static let dragThreshold: CGFloat = 4
    /// Wide enough for a useful title, narrow enough that one bookmark can
    /// never own the bar. Longer titles truncate.
    private static let maximumWidth: CGFloat = 220

    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false
    private var isPressed = false
    private var pressLocation: NSPoint?
    private var dragging = false

    init(node: BookmarkNode) {
        self.node = node
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        font = .systemFont(ofSize: 12)
        contentTintColor = .labelColor
        lineBreakMode = .byTruncatingTail
        title = node.displayTitle
        toolTip = node.isFolder ? node.displayTitle : (node.url ?? node.displayTitle)
        if node.isFolder {
            image = NSImage(
                systemSymbolName: "folder",
                accessibilityDescription: "Folder"
            )?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        // The press is tracked by hand rather than by the button cell, so a
        // drag can take over from a click: same shape as the tab cells.
        // The bar must never demand width; a long title compresses instead.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = min(size.width + 14, Self.maximumWidth)
        size.height = 22
        return size
    }

    override var acceptsFirstResponder: Bool { false }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        pressLocation = convert(event.locationInWindow, from: nil)
        isPressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - pressLocation.x
        let dy = point.y - pressLocation.y
        guard hypot(dx, dy) > Self.dragThreshold else { return }

        // Hand the drag over to AppKit and stop tracking the press.
        self.pressLocation = nil
        isPressed = false
        needsDisplay = true
        beginDrag(with: event, at: point)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressLocation != nil
        pressLocation = nil
        isPressed = false
        needsDisplay = true
        guard wasPressed, !dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onActivate?()
    }

    private func beginDrag(with event: NSEvent, at point: NSPoint) {
        let item = NSDraggingItem(pasteboardWriter: BookmarkPasteboardItem(id: node.id))
        let image = dragImage()
        let origin = NSPoint(x: image.size.width / 2, y: image.size.height / 2)
        item.setDraggingFrame(
            NSRect(
                origin: NSPoint(x: point.x - origin.x, y: point.y - origin.y),
                size: image.size
            ),
            contents: image
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func dragImage() -> NSImage {
        let size = bounds.size
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: size)
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - NSDraggingSource

    @objc func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    @objc func draggingSession(
        _ session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint
    ) {
        dragging = true
        alphaValue = 0.4
    }

    @objc func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dragging = false
        alphaValue = 1
    }

    /// Middle-click opens a link in a new tab, matching the tab bar.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let onMiddleClick else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        menu.popUp(
            positioning: nil,
            at: convert(event.locationInWindow, from: nil),
            in: self
        )
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            let path = NSBezierPath(
                roundedRect: bounds,
                xRadius: Self.fillRadius,
                yRadius: Self.fillRadius
            )
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        } else {
            let alpha = isPressed ? Self.pressedAlpha : (isHovering ? Self.hoverAlpha : 0)
            if isEnabled, alpha > 0 {
                let path = NSBezierPath(
                    roundedRect: bounds,
                    xRadius: Self.fillRadius,
                    yRadius: Self.fillRadius
                )
                NSColor.labelColor.withAlphaComponent(alpha).setFill()
                path.fill()
            }
        }
        super.draw(dirtyRect)
    }
}

extension BookmarkBarItemView: NSDraggingSource {}
