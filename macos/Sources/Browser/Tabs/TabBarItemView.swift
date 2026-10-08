import AppKit
import AVFoundation
import Combine

/// One tab cell in the custom tab bar: favicon/spinner, title, and a
/// close button that appears on hover or selection. The cell owns no
/// browser logic; every interaction is forwarded to `TabBarView`.
final class TabBarItemView: NSView {
    let tab: BrowserTab

    var onPress: (() -> Void)?
    var onClose: (() -> Void)?
    /// Silences or unsilences this tab, when its page is making sound.
    var onToggleMute: (() -> Void)?
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

    /// The globe every tab starts with, and the one it falls back to whenever a
    /// page has no icon of its own. Built once: there is one per cell and
    /// `NSImage` is not free to decode.
    private static let defaultFavicon: NSImage? = NSImage(
        systemSymbolName: "globe",
        accessibilityDescription: nil
    )

    private let backgroundView = NSView()
    private let faviconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton: NSButton
    private let audioButton: NSButton
    private var cancellables = Set<AnyCancellable>()
    private var trackingArea: NSTrackingArea?
    private var hover = false
    private var selected = false
    private var dragging = false
    private var pressLocation: NSPoint?
    private var isLoading = false
    /// Guards against rebuilding the symbol image on every appearance pass, which
    /// `layout` triggers often.
    private var appliedAudioSymbol: String?

    init(tab: BrowserTab) {
        self.tab = tab
        let button = NSButton(frame: .zero)
        button.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close Tab"
        )
        button.imagePosition = .imageOnly
        self.closeButton = button
        let audio = NSButton(frame: .zero)
        audio.imagePosition = .imageOnly
        audio.isHidden = true
        self.audioButton = audio
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

    /// A 1pt outline on the left, top and right edges, drawn like the spotlight's
    /// own chrome: same curve code, same coordinate system as the fill it follows.
    /// The square bottom edge meets the page, so bordering it would draw a line
    /// across the joint.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Snapped to device pixels, centered rather than shrunk: the strip divides
        // its width between cells, so bounds are routinely fractional, and a 1pt
        // stroke straddling pixels renders soft and uneven. Rounding (not flooring)
        // keeps the border concentric with the fill underneath instead of walking
        // off it.
        var rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        if let scale = window?.backingScaleFactor, scale > 0 {
            let minX = round(rect.minX * scale) / scale
            let minY = round(rect.minY * scale) / scale
            let maxX = round(rect.maxX * scale) / scale
            let maxY = round(rect.maxY * scale) / scale
            rect = NSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
        // Concentric with the layer's own 8pt corners: inset half the stroke.
        let path = SpotlightField.topSidesPath(in: rect, topRadius: 8 - 0.5)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func setUpSubviews() {
        backgroundView.isHidden = true
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        backgroundView.layer?.masksToBounds = true
        addSubview(backgroundView)

        faviconView.image = Self.defaultFavicon
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

        audioButton.target = self
        audioButton.action = #selector(audioTapped)
        audioButton.isBordered = false
        audioButton.contentTintColor = .secondaryLabelColor
        // Added after the close button so it sits in front of the title, matching
        // how the spinner sits in front of the favicon.
        addSubview(audioButton)
        applyAudioState()
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

        // Both funnel into one handler: the icon and the room it takes in the
        // cell are the same fact, and a tab's title has to give way either way.
        tab.tabController.$isProducingAudio
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.audioStateChanged()
            }
            .store(in: &cancellables)

        tab.tabController.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.audioStateChanged()
            }
            .store(in: &cancellables)

        // A page with no icon of its own reports nil, which is the globe the
        // image view already holds, so this never has to clear it back.
        tab.tabController.$favicon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                guard let image else { return }
                self?.faviconView.image = image
            }
            .store(in: &cancellables)

        // Tab chrome theming: the active cell reads its own configuration,
        // every other cell the shared one. `removeDuplicates` keeps slider
        // drags in Settings from rebuilding media layers per tick.
        SettingsStore.shared.$settings
            .map { ($0.appearance.tabTheme, $0.appearance.activeTabTheme) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyTheme() }
            .store(in: &cancellables)

        applyLoading(tab.tabController.isLoading)
    }

    deinit {
        if let videoPath {
            TabVideoPool.shared.release(path: videoPath)
        }
    }

    private func audioStateChanged() {
        applyAudioState()
        needsLayout = true
    }

    /// Whether this cell shows the mute button.
    ///
    /// Shown while the page is making sound, and kept while the tab is muted so a
    /// silenced tab stays findable after its audio stops. It sits between the
    /// favicon and the title rather than replacing either, so a tab that is both
    /// loading and audible still shows what it is doing. Not on a pinned tab: that
    /// cell is 44pt wide with room for a favicon only.
    private var showsAudioButton: Bool {
        tab.presentation.isPinned ? false : tab.tabController.isProducingAudio || tab.tabController.isMuted
    }

    private func applyAudioState() {
        let symbol = tab.tabController.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        if symbol != appliedAudioSymbol {
            appliedAudioSymbol = symbol
            let label = tab.tabController.isMuted ? "Unmute Tab" : "Mute Tab"
            audioButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            audioButton.toolTip = label
        }
        updateLeadingIcon()
    }

    /// Chooses which indicators show.
    ///
    /// The favicon and the spinner are alternatives for the same slot, while the
    /// mute indicator is independent of both: it only appears when there is
    /// something to mute, and it stays for the rest of the tab's life once used.
    private func updateLeadingIcon() {
        audioButton.isHidden = !showsAudioButton
        faviconView.isHidden = isLoading
        spinner.isHidden = !isLoading
        if isLoading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func applyLoading(_ isLoading: Bool) {
        self.isLoading = isLoading
        updateLeadingIcon()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func audioTapped() {
        onToggleMute?()
    }

    private func updateAppearance() {
        backgroundView.isHidden = false
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

    /// Media layer for the themed background (gradient, image, or video),
    /// or nil for solid colours, which paint the host layer directly.
    private var mediaLayer: CALayer?
    /// Pool path held while the theme is a video, released on change and
    /// teardown.
    private var videoPath: String?
    /// What `applyTheme` last built, so layout passes and unrelated settings
    /// ticks do not rebuild media layers.
    private var appliedThemeKey: (config: TabThemeConfiguration, selected: Bool)?

    /// Paints the cell's configured theme. The state washes above (dragging,
    /// selected, hover) are untouched: they composite over the theme, so a
    /// selected video tab still reads as selected.
    private func applyTheme() {
        let settings = SettingsStore.shared.settings.appearance
        let config = selected ? settings.activeTabTheme : settings.tabTheme
        if let applied = appliedThemeKey, applied == (config, selected) {
            return
        }
        mediaLayer?.removeFromSuperlayer()
        mediaLayer = nil
        if let videoPath {
            TabVideoPool.shared.release(path: videoPath)
            self.videoPath = nil
        }
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
                // Animated image: the first frame is the resting contents so
                // the loop failing still leaves the poster, and the loop dies
                // with the layer on the next theme change.
                let layer = CALayer()
                layer.contents = frames[0].image
                layer.contentsGravity = .resizeAspectFill
                layer.contentsScale = window?.backingScaleFactor ?? 2
                installMediaLayer(layer)
                if let loop = AnimatedImage.loopAnimation(frames: frames) {
                    layer.add(loop, forKey: "contentsLoop")
                }
            } else if let image = TabThemeMedia.image(at: path) {
                let layer = CALayer()
                layer.contents = image
                layer.contentsGravity = .resizeAspectFill
                layer.contentsScale = window?.backingScaleFactor ?? 2
                installMediaLayer(layer)
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

        if let foreground = config.foreground?.nsColor {
            titleLabel.textColor = foreground
            closeButton.contentTintColor = foreground
            audioButton.contentTintColor = foreground
            faviconView.contentTintColor = foreground
        } else {
            titleLabel.textColor = selected ? .labelColor : .secondaryLabelColor
            closeButton.contentTintColor = .secondaryLabelColor
            audioButton.contentTintColor = .secondaryLabelColor
            faviconView.contentTintColor = .secondaryLabelColor
        }
    }

    private func installMediaLayer(_ layer: CALayer) {
        layer.frame = backgroundView.bounds
        backgroundView.layer?.addSublayer(layer)
        mediaLayer = layer
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

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        // The media fills the cell at any size; gradient geometry is unit
        // space, so only the frame needs tracking.
        mediaLayer?.frame = backgroundView.bounds
        // The border is drawn, not layered, so it repaints with every layout.
        needsDisplay = true
        updateAppearance()

        let sideInset: CGFloat = tab.presentation.isPinned ? 0 : 8
        let iconSize: CGFloat = 16
        let y = (bounds.height - iconSize) / 2
        let faviconRect = NSRect(x: sideInset, y: y, width: iconSize, height: iconSize)

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
            audioButton.isHidden = true
            return
        }

        titleLabel.isHidden = false
        // Favicon and spinner share the leading slot; the mute indicator follows
        // it, and the title follows both.
        faviconView.frame = faviconRect
        spinner.frame = faviconRect

        let audioSize: CGFloat = 14
        if showsAudioButton {
            audioButton.frame = NSRect(
                x: faviconRect.maxX + 4,
                y: (bounds.height - audioSize) / 2,
                width: audioSize,
                height: audioSize
            )
        } else {
            audioButton.frame = .zero
        }

        let closeSize: CGFloat = 14
        closeButton.frame = NSRect(
            x: bounds.maxX - sideInset - closeSize,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
        // Only moves for the mute indicator while it is showing, so a tab that is
        // neither audible nor muted lays out exactly as it did before.
        let leadingEdge = showsAudioButton ? audioButton.frame.maxX : faviconRect.maxX
        let titleX = leadingEdge + 6
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
