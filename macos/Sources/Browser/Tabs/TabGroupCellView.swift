import AppKit
import Combine

/// One cell for a whole split group: two titles with their own favicons and
/// a single close button. The pair reads as one larger tab; clicking it
/// shows the split, and dragging it moves both tabs together.
///
/// Styling follows `TabBarItemView` (washes, outline, hover close) but
/// deliberately not tab themes: a media background belongs to one tab, and
/// stretching either member's over both halves would mislabel one of them.
final class TabGroupCellView: NSView {
    var onPress: (() -> Void)?
    var onClose: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    /// Called with the screen point when a drag session ends, so the
    /// owner can check whether it landed anywhere.
    var onDragEnded: ((NSPoint) -> Void)?

    /// Movement before a press becomes a drag, so a click that wobbles
    /// still selects instead of starting a drag session.
    private static let dragThreshold: CGFloat = 5

    private static let defaultFavicon: NSImage? = NSImage(
        systemSymbolName: "globe",
        accessibilityDescription: nil
    )

    private var leading: BrowserTab
    private var trailing: BrowserTab

    private let leadingFavicon = NSImageView()
    private let leadingTitle = NSTextField(labelWithString: "")
    private let trailingFavicon = NSImageView()
    private let trailingTitle = NSTextField(labelWithString: "")
    private let divider = NSView()
    private let closeButton: NSButton
    private var cancellables = Set<AnyCancellable>()
    private var trackingArea: NSTrackingArea?
    private var hover = false
    private var selected = false
    private var dragging = false
    private var pressLocation: NSPoint?

    init(leading: BrowserTab, trailing: BrowserTab) {
        self.leading = leading
        self.trailing = trailing
        let button = NSButton(frame: .zero)
        button.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close Tabs"
        )
        button.imagePosition = .imageOnly
        self.closeButton = button
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        // Same top-only rounding as a lone cell: the square bottom meets
        // the page edge so the group reads as attached to it.
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(leadingFavicon)
        addSubview(leadingTitle)
        addSubview(divider)
        addSubview(trailingFavicon)
        addSubview(trailingTitle)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        addSubview(closeButton)
        setUpContent()
        bind()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Re-points the cell at a new pair, re-binding titles and favicons.
    /// The strip reuses one cell for the window's life rather than
    /// rebuilding per regroup.
    func configure(leading: BrowserTab, trailing: BrowserTab) {
        guard leading.id != self.leading.id || trailing.id != self.trailing.id else { return }
        self.leading = leading
        self.trailing = trailing
        bind()
        needsLayout = true
    }

    func setSelected(_ isSelected: Bool) {
        selected = isSelected
        updateAppearance()
        needsLayout = true
    }

    func setDragging(_ isDragging: Bool) {
        dragging = isDragging
        updateAppearance()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        pressLocation = convert(event.locationInWindow, from: nil)
        onPress?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - pressLocation.x
        let dy = point.y - pressLocation.y
        guard hypot(dx, dy) > Self.dragThreshold else { return }

        self.pressLocation = nil
        let item = NSDraggingItem(pasteboardWriter: GroupPasteboardWriter(ids: [leading.id, trailing.id]))
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

    override func mouseUp(with event: NSEvent) {
        pressLocation = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
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
        setDragging(true)
    }

    @objc func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        setDragging(false)
        onDragEnded?(screenPoint)
    }

    private func dragImage() -> NSImage {
        let size = bounds.size.width > 0 ? bounds.size : NSSize(width: 340, height: 28)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: size)
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        updateAppearance()
    }

    // MARK: - Private

    private func setUpContent() {
        for favicon in [leadingFavicon, trailingFavicon] {
            favicon.image = Self.defaultFavicon
            favicon.imageScaling = .scaleProportionallyDown
            favicon.contentTintColor = .secondaryLabelColor
        }
        for title in [leadingTitle, trailingTitle] {
            title.lineBreakMode = .byTruncatingTail
            title.font = .systemFont(ofSize: 12, weight: .medium)
        }
    }

    private func bind() {
        cancellables.removeAll()
        leadingTitle.stringValue = leading.tabController.title
        trailingTitle.stringValue = trailing.tabController.title
        toolTip = "\(leading.tabController.title) — \(trailing.tabController.title)"
        leading.tabController.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                self?.leadingTitle.stringValue = title
                self?.updateToolTip()
            }
            .store(in: &cancellables)
        trailing.tabController.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                self?.trailingTitle.stringValue = title
                self?.updateToolTip()
            }
            .store(in: &cancellables)
        leading.tabController.$favicon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                guard let image else { return }
                self?.leadingFavicon.image = image
            }
            .store(in: &cancellables)
        trailing.tabController.$favicon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                guard let image else { return }
                self?.trailingFavicon.image = image
            }
            .store(in: &cancellables)
    }

    private func updateToolTip() {
        toolTip = "\(leadingTitle.stringValue) — \(trailingTitle.stringValue)"
    }

    @objc private func closeTapped() {
        onClose?()
    }

    private func updateAppearance() {
        if dragging {
            layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.35).cgColor
        } else if selected {
            layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.22).cgColor
        } else if hover {
            layer?.backgroundColor = NSColor.secondaryLabelColor
                .withAlphaComponent(0.12).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        leadingTitle.textColor = selected ? .labelColor : .secondaryLabelColor
        trailingTitle.textColor = selected ? .labelColor : .secondaryLabelColor
        closeButton.isHidden = !(hover || selected)
        closeButton.alphaValue = selected ? 1 : 0.7
    }

    /// Snapshot of the cell used as the drag image, plus the divider between
    /// the titles.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        if let scale = window?.backingScaleFactor, scale > 0 {
            let minX = round(rect.minX * scale) / scale
            let minY = round(rect.minY * scale) / scale
            let maxX = round(rect.maxX * scale) / scale
            let maxY = round(rect.maxY * scale) / scale
            rect = NSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
        let path = SpotlightField.topSidesPath(in: rect, topRadius: 8 - 0.5)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        updateAppearance()

        let iconSize: CGFloat = 16
        let y = (bounds.height - iconSize) / 2
        let closeSize: CGFloat = 14
        closeButton.frame = NSRect(
            x: bounds.maxX - 8 - closeSize,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
        // Two equal halves between the leading edge and the close button,
        // with a 1pt divider where they meet.
        let halvesWidth = max(0, closeButton.frame.minX - 4)
        let halves = NSRect(
            x: 0, y: 0,
            width: halvesWidth,
            height: bounds.height
        ).divided(atDistance: halvesWidth / 2, from: .minXEdge)
        divider.frame = NSRect(
            x: halves.slice.maxX - 0.5,
            y: 6,
            width: 1,
            height: max(0, bounds.height - 12)
        )
        layHalf(favicon: leadingFavicon, title: leadingTitle, in: halves.slice, iconY: y, iconSize: iconSize)
        layHalf(favicon: trailingFavicon, title: trailingTitle, in: halves.remainder, iconY: y, iconSize: iconSize)
    }

    /// Favicon plus title inside one half, mirroring a lone cell's insets.
    private func layHalf(favicon: NSImageView, title: NSTextField, in rect: NSRect, iconY: CGFloat, iconSize: CGFloat) {
        favicon.frame = NSRect(x: rect.minX + 8, y: iconY, width: iconSize, height: iconSize)
        let titleX = favicon.frame.maxX + 6
        title.frame = NSRect(
            x: titleX,
            y: (bounds.height - 16) / 2,
            width: max(0, rect.maxX - 6 - titleX),
            height: 16
        )
    }
}

/// Pasteboard writer for a whole split group: the member IDs in pane
/// order, so the receiving side resolves the pair rather than one tab.
private final class GroupPasteboardWriter: NSObject, NSPasteboardWriting {
    private let ids: [UUID]

    init(ids: [UUID]) {
        self.ids = ids
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [TabDragPayload.type]
    }

    func pasteboardPropertyList(
        forType type: NSPasteboard.PasteboardType
    ) -> Any? {
        guard type == TabDragPayload.type else { return nil }
        return ids.map(\.uuidString).joined(separator: "\n")
    }
}

extension TabGroupCellView: NSDraggingSource {}
