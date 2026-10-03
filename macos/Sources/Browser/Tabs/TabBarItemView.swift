import AppKit
import Combine

/// One tab cell in the custom tab bar: favicon/spinner, title, and a
/// close button that appears on hover or selection. The cell owns no
/// browser logic; every interaction is forwarded to `TabBarView`.
final class TabBarItemView: NSView {
    let tab: BrowserTab

    var onPress: (() -> Void)?
    var onClose: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    /// Called with the screen point when a drag session ends, so the
    /// owner can check whether it landed anywhere.
    var onDragEnded: ((NSPoint) -> Void)?

    static let pinnedWidth: CGFloat = 44
    static let minimumWidth: CGFloat = 90
    static let maximumWidth: CGFloat = 220
    static let preferredWidth: CGFloat = 170

    /// Movement before a press becomes a drag, so a click that wobbles
    /// still selects instead of starting a drag session.
    private static let dragThreshold: CGFloat = 5

    private let backgroundView = NSView()
    private let faviconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton: NSButton
    private var cancellables = Set<AnyCancellable>()
    private var trackingArea: NSTrackingArea?
    private var hover = false
    private var selected = false
    private var dragging = false
    private var pressLocation: NSPoint?

    init(tab: BrowserTab) {
        self.tab = tab
        let button = NSButton(frame: .zero)
        button.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close Tab"
        )
        button.imagePosition = .imageOnly
        self.closeButton = button
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        // Only the top corners are rounded; the square bottom corners
        // meet the page edge so the cell reads as attached to it. This
        // view is not flipped, so the visual top is maxY.
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true
        // The strip lays tab cells out manually.
        translatesAutoresizingMaskIntoConstraints = false
        setUpSubviews()
        bind(to: tab)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - State

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

        // Hand the drag over to AppKit and stop tracking the press.
        self.pressLocation = nil
        let item = NSDraggingItem(
            pasteboardWriter: tab
        )
        let image = dragImage()
        let origin = NSPoint(x: image.size.width / 2, y: image.size.height / 2)
        item.setDraggingFrame(
            NSRect(
                origin: NSPoint(
                    x: point.x - origin.x,
                    y: point.y - origin.y
                ),
                size: image.size
            ),
            contents: image
        )
        beginDraggingSession(
            with: [item],
            event: event,
            source: self
        )
    }

    override func mouseUp(with event: NSEvent) {
        pressLocation = nil
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

    /// Tab-bar and page-area drops consume the drag, so a session that
    /// ends over neither is one that ended outside the application.
    @objc func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        setDragging(false)
        onDragEnded?(screenPoint)
    }

    /// Snapshot of the cell used as the drag image.
    private func dragImage() -> NSImage {
        let size = bounds.size.width > 0 ? bounds.size : NSSize(width: 170, height: 28)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: size)
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
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

    private func setUpSubviews() {
        backgroundView.isHidden = true
        addSubview(backgroundView)

        faviconView.image = NSImage(
            systemSymbolName: "globe",
            accessibilityDescription: nil
        )
        faviconView.imageScaling = .scaleProportionallyDown
        faviconView.contentTintColor = .secondaryLabelColor
        addSubview(faviconView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.stringValue = tab.tabController.title
        addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        addSubview(closeButton)
    }

    private func bind(to tab: BrowserTab) {
        tab.tabController.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                self?.titleLabel.stringValue = title
            }
            .store(in: &cancellables)

        tab.tabController.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                self?.applyLoading(isLoading)
            }
            .store(in: &cancellables)

        tab.presentation.$isPinned
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.needsLayout = true
            }
            .store(in: &cancellables)

        applyLoading(tab.tabController.isLoading)
    }

    private func applyLoading(_ isLoading: Bool) {
        spinner.isHidden = !isLoading
        faviconView.isHidden = isLoading
        if isLoading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    @objc private func closeTapped() {
        onClose?()
    }

    private func updateAppearance() {
        backgroundView.isHidden = false
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
        titleLabel.textColor = selected ? .labelColor : .secondaryLabelColor
        closeButton.isHidden = !(hover || selected)
        closeButton.alphaValue = selected ? 1 : 0.7
    }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        updateAppearance()

        let sideInset: CGFloat = tab.presentation.isPinned ? 0 : 8
        let iconSize: CGFloat = 16
        let y = (bounds.height - iconSize) / 2

        if tab.presentation.isPinned {
            faviconView.frame = NSRect(
                x: (bounds.width - iconSize) / 2,
                y: y,
                width: iconSize,
                height: iconSize
            )
            spinner.frame = faviconView.frame
            titleLabel.isHidden = true
            closeButton.isHidden = true
            return
        }

        titleLabel.isHidden = false
        faviconView.frame = NSRect(x: sideInset, y: y, width: iconSize, height: iconSize)
        spinner.frame = faviconView.frame

        let closeSize: CGFloat = 14
        closeButton.frame = NSRect(
            x: bounds.maxX - sideInset - closeSize,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
        let titleX = faviconView.frame.maxX + 6
        let titleMaxX = closeButton.frame.minX - 4
        titleLabel.frame = NSRect(
            x: titleX,
            y: (bounds.height - 16) / 2,
            width: max(0, titleMaxX - titleX),
            height: 16
        )
    }
}

extension TabBarItemView: NSDraggingSource {}
