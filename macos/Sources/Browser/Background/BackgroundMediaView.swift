import AppKit

/// The last background problem, shared so the settings pane can show it.
///
/// A tiny observable rather than a parameter threaded through the window: the
/// failure is detected in a view owned by the window and has to be reported in a
/// pane owned by the settings card, and the only thing connecting them is the
/// store.
@MainActor
final class BackgroundDiagnostics: ObservableObject {
    static let shared = BackgroundDiagnostics()

    @Published private(set) var lastError: String?

    private init() {}

    func report(_ message: String) {
        lastError = message
    }

    func clear() {
        lastError = nil
    }
}

/// Something that went wrong with the window background.
///
/// Every case resolves to the background being cleared rather than to the view
/// misbehaving, because a wallpaper is never a good reason for a window to stop
/// drawing its page.
enum BackgroundMediaError: Equatable {
    case unreadableFile(path: String)
    case unsupportedImage(path: String)
    case unsupportedVideo(path: String)
    case videoPlaybackFailed(String)

    var message: String {
        switch self {
        case .unreadableFile(let path):
            "Could not read \(URL(fileURLWithPath: path).lastPathComponent)."
        case .unsupportedImage(let path):
            "\(URL(fileURLWithPath: path).lastPathComponent) is not an image this can show."
        case .unsupportedVideo(let path):
            "\(URL(fileURLWithPath: path).lastPathComponent) is not a video this can play."
        case .videoPlaybackFailed(let reason):
            "The background video stopped: \(reason)"
        }
    }
}

/// The window background: a colour, a gradient, an image or a video, drawn
/// behind everything the window shows.
///
/// Event transparency is structural rather than a flag, copied from
/// `NoiseOverlayView`: `hitTest` always answers nil, so presses, scrolls, hover,
/// drags, gestures and keyboard focus behave exactly as if this view were not
/// there. That matters more here than for the grain, because this view covers
/// the entire window rather than sitting above a page.
///
/// Layer order is `zPosition = -1`, the mirror of the grain's `999`. Subview
/// order alone would already put it behind the tab bar and every page, since
/// children are appended as they arrive, but a negative z-order means a view
/// added later cannot end up in front of it by accident.
///
/// Drawing is a single `draw(_:)` path so tiling, positioning and sizing are
/// resolved in one place. Redraws come only from bounds, configuration,
/// appearance or backing-scale changes; there is no timer and no per-frame work.
final class BackgroundMediaView: NSView {
    /// Below everything in the window. See the note above.
    static let zPosition: CGFloat = -1

    /// Reported instead of being drawn. Left nil in practice: failures go straight
    /// to `BackgroundDiagnostics`, because the view that detects them is owned by
    /// a window and the place they have to appear is a settings pane.
    var onError: ((BackgroundMediaError) -> Void)?

    var configuration: BackgroundMediaConfiguration = .init() {
        didSet {
            if oldValue != configuration { apply() }
        }
    }

    /// Suspends video without changing what is configured, for when the window
    /// is not worth spending power on.
    var isPlaybackSuspended = false {
        didSet {
            if isPlaybackSuspended != oldValue { updatePlayback() }
        }
    }

    private var imageStore = BackgroundImageStore()
    /// The decoded, downsampled and colour-graded still for the current image or
    /// video poster. Nil until a file has been read.
    private var image: CGImage?
    private var imageToken: BackgroundImageStore.Token?
    /// Pixel width the current still was decoded for. Zero before the first
    /// decode, so the install-time request (which runs before layout, when
    /// bounds are still zero) is recognised as undersized and redone once
    /// the view knows its size.
    private var decodedPixelSize = 0
    /// Pixel width the in-flight request asked for, stored so the completion
    /// can record what actually landed.
    private var requestedPixelSize = 0
    /// Decode sizes are rounded up to whole buckets, so a live resize
    /// re-decodes a few times rather than once per pixel, and moving between
    /// same-bucket sizes is a cache hit instead of a re-decode.
    private static let decodeBucket: CGFloat = 512
    private let videoLayer = BackgroundVideoLayerView()
    /// Above `videoLayer`, so a tint tints the video too and not just the stills.
    private let overlayView = BackgroundOverlayView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = Self.zPosition
        // The default policy stretches the cached bitmap on resize, which turns a
        // downsampled wallpaper into visible blocks.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        videoLayer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoLayer)
        // Order is the whole point: equal z-positions, and the later subview wins,
        // so the tint lands above the player.
        addSubview(overlayView)
        NSLayoutConstraint.activate([
            videoLayer.topAnchor.constraint(equalTo: topAnchor),
            videoLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        videoLayer.onError = { [weak self] error in
            // An unplayable video means there is no background, so it is turned
            // off in the store rather than left configured and failing silently.
            BackgroundDiagnostics.shared.report(error.message)
            self?.onError?(error)
            SettingsStore.shared.update { $0.appearance.background.kind = .none }
        }
        videoLayer.onFirstFrame = { [weak self] in self?.needsDisplay = true }
        apply()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Event transparency

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var isOpaque: Bool {
        false
    }

    // MARK: - Placement

    /// One background per parent, covering it completely.
    ///
    /// Pinned to the parent's bounds rather than its safe area, which is the
    /// point of the window being full-size: the media is meant to run up behind
    /// the toolbar and titlebar, where the chrome is transparent.
    @discardableResult
    static func install(in parent: NSView) -> BackgroundMediaView {
        if let existing = parent.subviews.compactMap({ $0 as? BackgroundMediaView }).first {
            return existing
        }
        let background = BackgroundMediaView(frame: parent.bounds)
        background.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(background, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: parent.topAnchor),
            background.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
        return background
    }

    // MARK: - Redraw triggers

    override func layout() {
        super.layout()
        // The install-time decode runs before layout, while bounds are still
        // zero, so without this the view keeps a postage-stamp bitmap
        // stretched over the window for the rest of the launch. Upscale
        // only: shrinking the window keeps the larger bitmap it already has.
        guard neededPixelSize() > decodedPixelSize else { return }
        switch configuration.kind {
        case .image:
            reloadMedia(path: configuration.path, isFatal: true)
        case .video:
            reloadMedia(path: configuration.video.posterPath, isFatal: false)
        case .none, .solid, .gradient:
            break
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A wallpaper decoded for one screen's pixel density is soft on the
        // other, so re-read it at the new scale.
        switch configuration.kind {
        case .image:
            reloadMedia(path: configuration.path, isFatal: true)
        case .video:
            reloadMedia(path: configuration.video.posterPath, isFatal: false)
        case .none, .solid, .gradient:
            break
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Configuration

    func apply() {
        isHidden = !configuration.isActive
        switch configuration.kind {
        case .none, .solid, .gradient:
            imageToken = nil
            image = nil
        case .image:
            reloadMedia(path: configuration.path, isFatal: true)
        case .video:
            // The poster is a separate, optional file. The player draws its own
            // first frame once it is ready, so the video itself is never decoded
            // as an image, and a missing or unreadable poster must not take the
            // background down with it.
            reloadMedia(path: configuration.video.posterPath, isFatal: false)
        }
        // Opacity rides on the view rather than being composited into the draw,
        // so changing strength never re-renders anything. It also happens to be
        // the reason the tint lives in a subview: a layer's opacity multiplies its
        // whole subtree, so the video fades with everything else, while a tint
        // painted into this view's own layer would be underneath the player and
        // stay at full strength however far the opacity went.
        alphaValue = min(max(configuration.effects.opacity, 0), 1)
        updateOverlay()
        updatePlayback()
        needsDisplay = true
    }

    /// Hands the flat tint to the overlay view, which is the only way it can reach
    /// a video: `draw(_:)` paints into this view's layer and `AVPlayerLayer` is a
    /// sublayer above it.
    private func updateOverlay() {
        let overlay = configuration.effects.overlay
        let isVisible = overlay.alpha > 0.001
        // Hidden rather than left transparent, so an untinted video is not
        // composited through an empty layer it does not need.
        overlayView.isHidden = !isVisible
        overlayView.color = isVisible ? overlay : nil
    }

    func setMedia(path: String?) {
        var next = configuration
        next.path = path
        configuration = next
    }

    func clear() {
        var next = BackgroundMediaConfiguration()
        next.path = configuration.path
        next.showThroughPages = false
        configuration = next
    }

    /// Reads a file for the still image behind the view.
    ///
    /// `isFatal` is what separates the two callers: an image whose file is broken
    /// means there is no background, so the setting is turned off in the store as
    /// well as locally. A poster that cannot be read is only a missing nicety,
    /// because the player is about to supply a frame of its own.
    private func reloadMedia(path: String?, isFatal: Bool) {
        guard let path, !path.isEmpty else {
            imageToken = nil
            image = nil
            return
        }
        // Bounded by the screen's pixel density: decoding a 6K wallpaper at full
        // size costs hundreds of megabytes to fill a window that can never show
        // more than a couple of thousand pixels across. Zero before layout, in
        // which case there is nothing to decode for yet; `layout` retries once
        // the view knows its size.
        let maxPixelSize = neededPixelSize()
        guard maxPixelSize > 0 else { return }
        let token = imageStore.load(
            path: path,
            maxPixelSize: maxPixelSize,
            effects: configuration.effects,
            completion: { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A request for media this view has since replaced must not
                    // land on it.
                    guard result.token == self.imageToken else { return }
                    switch result.loaded {
                    case .success(let cgImage):
                        self.image = cgImage
                        self.decodedPixelSize = self.requestedPixelSize
                        self.needsDisplay = true
                    case .failure(let error):
                        // Reported before anything is changed, so the pane can say
                        // what went wrong even if the background is about to go.
                        BackgroundDiagnostics.shared.report(error.message)
                        self.onError?(error)
                        self.image = nil
                        guard isFatal else { return }
                        // Drop back to no background rather than leaving a blank
                        // window or retrying forever on a bad path. Written to the
                        // store as well as locally, so the pane does not keep
                        // showing a file that is already known to be unusable.
                        SettingsStore.shared.update {
                            $0.appearance.background.kind = .none
                        }
                    }
                }
            }
        )
        imageToken = token
        requestedPixelSize = maxPixelSize
    }

    /// Window's larger dimension in pixels, rounded up to a whole decode
    /// bucket. Zero while the view has no size, which is also the install
    /// state before layout.
    private func neededPixelSize() -> Int {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let raw = max(bounds.width, bounds.height) * scale
        guard raw > 0 else { return 0 }
        return Int((ceil(raw / Self.decodeBucket) * Self.decodeBucket).rounded())
    }

    private func updatePlayback() {
        let isVideo = configuration.kind == .video
        videoLayer.isHidden = !isVideo
        // The path only goes to the player when the video renderer is the active
        // one. Handing an image's path to `AVURLAsset` reported the image as an
        // unplayable video, and a solid fill with a stale path did the same.
        videoLayer.apply(
            path: isVideo ? configuration.path : nil,
            options: configuration.video,
            fit: configuration.fit,
            isActive: configuration.isActive,
            isSuspended: isPlaybackSuspended || configuration.effects.opacity <= 0.001
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        switch configuration.kind {
        case .none:
            return
        case .solid:
            context.saveGState()
            configuration.solid.color.nsColor.setFill()
            bounds.fill(using: .sourceOver)
            context.restoreGState()
        case .gradient:
            drawGradient(in: context)
        case .image:
            drawImage(in: context)
        case .video:
            // The poster stands in until the player reports a frame.
            drawImage(in: context)
        }
    }

    private func drawGradient(in context: CGContext) {
        let gradient = configuration.gradient
        guard gradient.isUsable else { return }
        let stops = gradient.stops.sorted { $0.location < $1.location }
        let colors = stops.map { $0.color.nsColor.cgColor } as CFArray
        let locations = stops.map { CGFloat($0.location) }
        guard let cgGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) else { return }

        context.saveGState()
        switch gradient.kind {
        case .linear:
            context.drawLinearGradient(
                cgGradient,
                start: Self.point(for: gradient.angle, in: bounds, radius: 0),
                end: Self.point(for: gradient.angle, in: bounds, radius: bounds.height / 2),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        case .radial:
            let center = CGPoint(
                x: bounds.width * CGFloat(min(max(gradient.centerX, 0), 1)),
                y: bounds.height * CGFloat(min(max(gradient.centerY, 0), 1))
            )
            let shorter = min(bounds.width, bounds.height)
            context.drawRadialGradient(
                cgGradient,
                startCenter: center,
                startRadius: shorter * CGFloat(min(max(gradient.startRadius, 0), 1)),
                endCenter: center,
                endRadius: shorter * CGFloat(min(max(gradient.endRadius, 0), 1)),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    /// Endpoints for a linear gradient at `angle` degrees, measured clockwise
    /// from straight up so 90 is the familiar left-to-right CSS `to right`.
    private static func point(for angle: Double, in rect: NSRect, radius: CGFloat) -> CGPoint {
        let radians = (angle - 90) * .pi / 180
        let dx = cos(radians) * radius
        let dy = sin(radians) * radius
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return CGPoint(x: center.x + dx, y: center.y + dy)
    }

    private func drawImage(in context: CGContext) {
        guard let image else { return }
        let intrinsic = NSSize(width: image.width, height: image.height)
        let viewport = bounds.size
        context.saveGState()
        // Filtering matters for the downsampled case: without it a large source
        // scaled down to the window aliases badly.
        context.interpolationQuality = .high
        defer { context.restoreGState() }

        if configuration.repeatsHorizontally || configuration.repeatsVertically {
            let size = configuration.mediaSize(intrinsic: intrinsic, viewport: viewport)
            guard size.width > 0, size.height > 0 else { return }
            // Grid-aligned so the phase is stable between draws and a resize does
            // not make the pattern crawl.
            let startX = configuration.repeatsHorizontally
                ? floor(bounds.minX / size.width) * size.width
                : 0
            let startY = configuration.repeatsVertically
                ? floor(bounds.minY / size.height) * size.height
                : 0
            var y = startY
            while y < bounds.maxY {
                var x = startX
                while x < bounds.maxX {
                    context.draw(
                        image,
                        in: CGRect(
                            x: x,
                            y: y,
                            // The last row or column is clipped to the view
                            // rather than drawn past it.
                            width: min(size.width, bounds.maxX - x),
                            height: min(size.height, bounds.maxY - y)
                        )
                    )
                    x += size.width
                }
                y += size.height
            }
            return
        }

        guard let rect = configuration.drawnRect(intrinsic: intrinsic, viewport: viewport) else { return }
        context.draw(image, in: rect)
    }
}

/// The flat colour laid over whatever the background drew.
///
/// This is a view rather than part of `BackgroundMediaView.draw(_:)` because a
/// video is drawn by `AVPlayerLayer`, which lives in a sublayer of a subview and
/// composites *above* anything the parent view paints into its own layer. A tint
/// painted in `draw` therefore sits underneath the video and does nothing for that
/// one kind, while looking perfectly fine for every other kind.
///
/// Non-interactive for the same structural reason as its parent, and marked so
/// directly rather than leaning on the parent's `hitTest` answering nil.
final class BackgroundOverlayView: NSView {
    /// Nil means no tint.
    var color: BackgroundColor? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Without this the autoresizing mask wins and the four edge constraints
        // added by `BackgroundMediaView` are quietly ignored, leaving the tint at
        // a 0x0 frame and invisible for a second, entirely separate reason.
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// The same two lines the parent used for its own tint, so a tinted video and
    /// a tinted image come out the same colour to the eye.
    override func draw(_ dirtyRect: NSRect) {
        guard let color, NSGraphicsContext.current != nil else { return }
        color.nsColor.setFill()
        bounds.fill(using: .sourceOver)
    }
}