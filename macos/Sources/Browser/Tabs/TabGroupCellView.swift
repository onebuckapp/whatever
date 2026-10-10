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
import AVFoundation
import Combine

/// One cell for a whole split group: two titles with their own favicons and
/// a single close button. The pair reads as one larger tab; clicking it
/// shows the split, and dragging it moves both tabs together.
///
/// Themes mirror a lone cell: the active tab's customization while a member
/// is selected, the inactive one otherwise.
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

    private let backgroundView = NSView()
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
    /// Media layer for the themed background (gradient, image, or video),
    /// or nil for solid colours, which paint the host layer directly.
    private var mediaLayer: CALayer?
    /// Pixel size of the image in `mediaLayer`, or nil when the media is
    /// not an image. Images draw at a computed frame (fit plus anchor)
    /// rather than filling the cell, so `layout` re-resolves it on resize.
    private var mediaImageSize: CGSize?
    /// Flat tint over the media (image or video), below the state washes.
    /// Torn down with the media layer; nil when the tint is transparent.
    private var tintLayer: CALayer?
    /// Pool path held while the theme is a video, released on change and
    /// teardown.
    private var videoPath: String?
    /// What `applyTheme` last built, so layout passes and unrelated settings
    /// ticks do not rebuild media layers.
    private var appliedThemeKey: (config: TabThemeConfiguration, selected: Bool)?

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
        backgroundView.isHidden = true
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        backgroundView.layer?.masksToBounds = true
        addSubview(backgroundView)
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

    /// Middle-click closes both members, matching the cell's single close
    /// button. Left-button press/drag tracking is untouched.
    override func otherMouseDown(with event: NSEvent) {
        onClose?()
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

    /// Sets the hover state directly. Same scroll-under-cursor case as the
    /// lone cell's — see its `setHovered`.
    func setHovered(_ hovered: Bool) {
        guard hover != hovered else { return }
        hover = hovered
        updateAppearance()
    }

    /// Whether the cell currently paints hovered. For tests.
    var isHoveredForTesting: Bool {
        hover
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
        // Tab chrome theming: the active cell reads its own configuration,
        // every other cell the shared one. `removeDuplicates` keeps slider
        // drags in Settings from rebuilding media layers per tick.
        SettingsStore.shared.$settings
            .map { ($0.appearance.tabTheme, $0.appearance.activeTabTheme, $0.appearance.tabCornerRadius, $0.appearance.tabShape) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyTheme()
                self?.applyCornerRadius()
            }
            .store(in: &cancellables)
        applyTheme()
        applyCornerRadius()
    }

    deinit {
        if let videoPath {
            TabVideoPool.shared.release(path: videoPath)
        }
    }

    private func updateToolTip() {
        toolTip = "\(leadingTitle.stringValue) — \(trailingTitle.stringValue)"
    }

    @objc private func closeTapped() {
        onClose?()
    }

    /// Corner roundness from Settings, shared with lone cells. Capped at
    /// half the cell height wherever it is used.
    private var cornerRadius: CGFloat = 8
    /// Cell shape from Settings, shared with lone cells.
    private var tabShape = TabShape.attached

    private func applyCornerRadius() {
        cornerRadius = CGFloat(
            SettingsStore.shared.settings.appearance.tabCornerRadius)
        tabShape = SettingsStore.shared.settings.appearance.tabShape
        // Layout too, like the lone cell: fills take their corners there,
        // and the shape moves the cell's own frame in the strip.
        needsLayout = true
        superview?.needsLayout = true
        needsDisplay = true
    }

    private func resolvedCornerRadius() -> CGFloat {
        tabShape.cornerRadius(setting: cornerRadius, height: bounds.height)
    }

    private func updateAppearance() {
        applyTheme()
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
        // Text colour lives in `applyTheme`, which runs just above: a custom
        // foreground replaces this, nil keeps it.
        closeButton.isHidden = !(hover || selected)
        closeButton.alphaValue = selected ? 1 : 0.7
    }

    // MARK: - Theme

    /// Paints the cell's configured theme: the active tab's customization
    /// while a member is selected, the inactive one otherwise. The state
    /// washes above (dragging, selected, hover) are untouched: they
    /// composite over the theme. Text colour lives here, not in
    /// `updateAppearance`, which runs just above.
    private func applyTheme() {
        let settings = SettingsStore.shared.settings.appearance
        let config = selected ? settings.activeTabTheme : settings.tabTheme
        if let applied = appliedThemeKey, applied == (config, selected) {
            return
        }
        mediaLayer?.removeFromSuperlayer()
        mediaLayer = nil
        mediaImageSize = nil
        tintLayer?.removeFromSuperlayer()
        tintLayer = nil
        if let videoPath {
            TabVideoPool.shared.release(path: videoPath)
            self.videoPath = nil
        }
        backgroundView.isHidden = false
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        backgroundView.layer?.contents = nil
        appliedThemeKey = (config, selected)

        switch config.background.kind {
        case .none:
            break
        case .solid:
            backgroundView.layer?.backgroundColor = config.background.solid.color.nsColor.cgColor
        case .gradient:
            guard let layer = Self.gradientLayer(config.background.gradient) else { break }
            installMediaLayer(layer)
        case .image:
            guard let path = config.background.path else { break }
            if let frames = TabThemeMedia.animation(at: path),
               !frames.isEmpty {
                installImageLayer(
                    contents: frames[0].image,
                    size: CGSize(width: frames[0].image.width, height: frames[0].image.height),
                    config: config
                )
                if let mediaLayer,
                   let loop = AnimatedImage.loopAnimation(frames: frames) {
                    mediaLayer.add(loop, forKey: "contentsLoop")
                }
            } else if let image = TabThemeMedia.image(at: path) {
                installImageLayer(contents: image, size: image.size, config: config)
            }
        case .video:
            guard let path = config.background.path,
                  let player = TabVideoPool.shared.acquire(path: path)
            else {
                break
            }
            videoPath = path
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            installMediaLayer(layer)
        }

        // Tint sits above the media — image, video, or anything else drawn —
        // and below the state washes, which `updateAppearance` composites over
        // it. Opacity fades the whole themed background (media plus tint) but
        // never the wash or the text above it.
        let overlay = config.background.effects.overlay
        if overlay.alpha > 0.001 {
            let layer = CALayer()
            layer.backgroundColor = overlay.nsColor.cgColor
            layer.frame = backgroundView.bounds
            backgroundView.layer?.addSublayer(layer)
            tintLayer = layer
        }
        backgroundView.layer?.opacity = Float(config.background.effects.opacity)

        if let foreground = config.foreground?.nsColor {
            leadingTitle.textColor = foreground
            trailingTitle.textColor = foreground
            closeButton.contentTintColor = foreground
            leadingFavicon.contentTintColor = foreground
            trailingFavicon.contentTintColor = foreground
        } else {
            leadingTitle.textColor = selected ? .labelColor : .secondaryLabelColor
            trailingTitle.textColor = selected ? .labelColor : .secondaryLabelColor
            closeButton.contentTintColor = .secondaryLabelColor
            leadingFavicon.contentTintColor = .secondaryLabelColor
            trailingFavicon.contentTintColor = .secondaryLabelColor
        }
    }

    private func installMediaLayer(_ layer: CALayer) {
        layer.frame = backgroundView.bounds
        backgroundView.layer?.addSublayer(layer)
        mediaLayer = layer
    }

    /// Installs an image at its fitted frame: fit plus anchor, not a blind
    /// fill. The frame is aspect-correct, so the gravity stretches nothing;
    /// the background view's clipping cuts the overflow.
    private func installImageLayer(contents: Any, size: CGSize, config: TabThemeConfiguration) {
        let layer = CALayer()
        layer.contents = contents
        layer.contentsGravity = .resize
        layer.contentsScale = window?.backingScaleFactor ?? 2
        mediaImageSize = size
        installMediaLayer(layer)
        layer.frame = TabThemeMedia.imageFrame(
            imageSize: size,
            in: backgroundView.bounds,
            fit: config.background.fit,
            scalePercent: config.background.fitScale,
            position: config.background.position
        )
    }

    /// Gradient honoring the stored stops, angle, and radial geometry, so a
    /// hand-set gradient renders rather than dropping to nothing.
    private static func gradientLayer(_ gradient: BackgroundMediaConfiguration.Gradient) -> CALayer? {
        guard gradient.isUsable else { return nil }
        let layer = CAGradientLayer()
        layer.colors = gradient.stops.map { $0.color.nsColor.cgColor }
        layer.locations = gradient.stops.map { NSNumber(value: $0.location) }
        switch gradient.kind {
        case .linear:
            // Degrees clockwise from pointing up; the unit-space diagonal
            // this spans covers the layer at any size.
            let radians = CGFloat(gradient.angle) * .pi / 180
            let dx = sin(radians) / 2
            let dy = cos(radians) / 2
            layer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 + dy)
            layer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 - dy)
        case .radial:
            layer.type = .radial
            layer.startPoint = CGPoint(x: gradient.centerX, y: gradient.centerY)
            let radius = max(0, gradient.endRadius - gradient.startRadius)
            layer.endPoint = CGPoint(x: gradient.centerX + radius, y: gradient.centerY)
        }
        return layer
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
        let outlineRadius = max(resolvedCornerRadius() - 0.5, 0)
        let path: NSBezierPath
        if tabShape.roundsBottomCorners {
            path = NSBezierPath(roundedRect: rect, xRadius: outlineRadius, yRadius: outlineRadius)
        } else {
            path = SpotlightField.topSidesPath(in: rect, topRadius: outlineRadius)
        }
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        let radius = resolvedCornerRadius()
        layer?.cornerRadius = radius
        backgroundView.layer?.cornerRadius = radius
        // Pills round every corner; attached cells keep the bottom square
        // so the group reads as joined to the page.
        let rounding = tabShape.layerRounding
        layer?.maskedCorners = rounding
        backgroundView.layer?.maskedCorners = rounding
        backgroundView.frame = bounds
        // Gradient and video geometry is unit space or live, so only the
        // frame needs tracking. Images carry an explicit fitted frame,
        // re-resolved here so resizes move the anchor with the cell.
        if let mediaLayer, let imageSize = mediaImageSize,
           let applied = appliedThemeKey {
            mediaLayer.frame = TabThemeMedia.imageFrame(
                imageSize: imageSize,
                in: backgroundView.bounds,
                fit: applied.config.background.fit,
                scalePercent: applied.config.background.fitScale,
                position: applied.config.background.position
            )
        } else {
            mediaLayer?.frame = backgroundView.bounds
        }
        tintLayer?.frame = backgroundView.bounds
        // The border is drawn, not layered, so it repaints with every layout.
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
        // with a 1pt divider where they meet. The split lands on a whole
        // point: a fractional middle puts both titles half a pixel off
        // the grid and they paint soft, like lone cells with fractional
        // edges do.
        let halvesWidth = max(0, closeButton.frame.minX - 4)
        let halves = NSRect(
            x: 0, y: 0,
            width: halvesWidth,
            height: bounds.height
        ).divided(atDistance: (halvesWidth / 2).rounded(), from: .minXEdge)
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
