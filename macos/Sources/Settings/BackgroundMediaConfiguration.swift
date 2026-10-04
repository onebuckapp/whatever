import AppKit

/// What fills the window behind the page.
///
/// Modelled on CSS background properties, with the naming kept distinct where
/// CSS reuses one word for two things: `repeatMode` tiles the media, while a video
/// always loops and offers no setting. They are unrelated, and the repeat control
/// is hidden for video rather than silently ignored.
///
/// Every field has a default and the whole type is `Codable`, so it is stored
/// verbatim in the settings document with no migration step. `.none` is the
/// default and means exactly the appearance from before this existed: the layer
/// is not installed, nothing about the page changes, and `showThroughPages`
/// becomes inert.
struct BackgroundMediaConfiguration: Codable, Equatable {
    /// Which of the renderers is active.
    enum Kind: String, Codable, CaseIterable, Identifiable {
        var id: String { rawValue }

        case none
        case solid
        case gradient
        case image
        case video

        var title: String {
            switch self {
            case .none: "None"
            case .solid: "Solid"
            case .gradient: "Gradient"
            case .image: "Image"
            case .video: "Video"
            }
        }

        // Which sections apply to which renderer.
        //
        // Derived from what the renderers read rather than from what each control
        // was written for, because a row that does nothing is worse than an
        // absent one: it looks like it is working. See `BackgroundMediaView.draw`
        // and `BackgroundVideoLayerView.apply` for the other end of this.

        /// Fit, Scale and the media file. A colour and a gradient are generated at
        /// window size, so there is nothing to size, place or point at a file.
        var showsMediaSize: Bool {
            self == .image || self == .video
        }

        /// Anchor and custom offsets.
        ///
        /// Never shown for video: `AVPlayerLayer.videoGravity` is the only lever
        /// it has and it expresses scaling, not placement, so this cannot be made
        /// to work and offering it would be a lie.
        var showsPlacement: Bool {
            self == .image
        }

        /// Tiling, which is image-only because `AVPlayerLayer` cannot tile.
        var showsRepeat: Bool {
            self == .image
        }

        /// Blur, brightness, contrast and saturation.
        ///
        /// These are baked into a decoded image by `BackgroundImageStore`, so they
        /// only reach anything that is an image: a file, or a video's poster. A
        /// video's own frames are never graded. A colour and a gradient are drawn
        /// straight into the context and have no detail for a filter to act on.
        func showsGrading(hasPoster: Bool) -> Bool {
            self == .image || (self == .video && hasPoster)
        }
    }

    /// How the media is scaled into the window.
    ///
    /// A mode plus a separate number rather than an enum with an associated
    /// value, so the whole set can drive a segmented control.
    enum Fit: String, Codable, CaseIterable, Identifiable {
        var id: String { rawValue }

        case original
        case contain
        case fill
        case stretch
        case custom

        var title: String {
            switch self {
            case .original: "Original"
            case .contain: "Fit"
            case .fill: "Fill"
            case .stretch: "Stretch"
            case .custom: "Scale"
            }
        }

        /// The only two that mean anything for a video.
        ///
        /// `BackgroundVideoLayerView` maps five cases onto `AVPlayerLayer`, which
        /// has exactly two relevant values: `resizeAspect` and `resizeAspectFill`.
        /// So three of these options would sit there looking distinct and doing
        /// the same thing as another.
        static let videoCases: [Fit] = [.contain, .fill]

        /// Which of those two the renderer will actually do, for a stored value.
        ///
        /// Read when drawing the control for a video, so switching from an image
        /// with `stretch` or a custom scale does not present a segmented control
        /// with nothing selected. Nothing is written back, so an image's fit comes
        /// back untouched when the kind returns to `.image`.
        var effectiveVideoFit: Fit {
            switch self {
            case .original, .contain: .contain
            case .fill, .stretch, .custom: .fill
            }
        }
    }

    /// Tiling. Images and gradients only: `AVPlayerLayer` has no tile mode.
    enum Repeat: String, Codable, CaseIterable, Identifiable {
        var id: String { rawValue }

        case none
        case horizontal
        case vertical
        case both

        var title: String {
            switch self {
            case .none: "None"
            case .horizontal: "Along X"
            case .vertical: "Along Y"
            case .both: "Both"
            }
        }
    }

    /// One edge or the middle, or a custom offset on each axis.
    enum Position: String, Codable, CaseIterable, Identifiable {
        var id: String { rawValue }

        case topLeft, topCenter, topRight
        case centerLeft, center, centerRight
        case bottomLeft, bottomCenter, bottomRight
        case custom

        var title: String {
            switch self {
            case .topLeft: "Top Left"
            case .topCenter: "Top Center"
            case .topRight: "Top Right"
            case .centerLeft: "Center Left"
            case .center: "Center"
            case .centerRight: "Center Right"
            case .bottomLeft: "Bottom Left"
            case .bottomCenter: "Bottom Center"
            case .bottomRight: "Bottom Right"
            case .custom: "Custom"
            }
        }
    }

    /// One axis of a custom position.
    struct Axis: Codable, Equatable {
        enum Mode: String, Codable, CaseIterable, Identifiable {
            var id: String { rawValue }

            case start, center, end, percent, point

            var title: String {
                switch self {
                case .start: "Start"
                case .center: "Center"
                case .end: "End"
                case .percent: "Percent"
                case .point: "Points"
                }
            }
        }

        var mode: Mode = .center
        /// Percent of the window's size when `mode` is `.percent`, points when
        /// it is `.point`. Unused otherwise, but stored so switching modes back
        /// and forth does not lose the number.
        var value: Double = 50

        func offset(in extent: CGFloat) -> CGFloat {
            switch mode {
            case .start: 0
            case .center: extent / 2
            case .end: extent
            case .percent: extent * CGFloat(min(max(value, 0), 100) / 100)
            case .point: CGFloat(value)
            }
        }
    }

    /// Opacity and colour grading, applied to the source once rather than per
    /// draw. See `BackgroundImageStore`.
    struct Effects: Codable, Equatable, Hashable {
        var opacity: Double = 1
        /// A flat colour over the media, and how strongly.
        var overlay: BackgroundColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
        /// Blur radius in points.
        var blurRadius: Double = 0
        /// All three are neutral at 1, and clamp rather than wrap, the way the
        /// matching CoreImage filters do.
        var brightness: Double = 1
        var contrast: Double = 1
        var saturation: Double = 1

        /// Whether any of this needs a filter run at all.
        var isIdentity: Bool {
            blurRadius <= 0.001
                && brightness == 1
                && contrast == 1
                && saturation == 1
        }
    }

    /// Playback for the video renderer.
    ///
    /// No mute and no loop setting, on purpose: a background video is always
    /// silent and always loops. A window that starts making noise on its own is
    /// the problem this whole feature exists to let the user solve, so there is
    /// no version of this worth offering a checkbox for, and a background that
    /// stops at the end is a frozen frame nobody asked for.
    struct VideoOptions: Codable, Equatable {
        /// Whether the video starts on its own.
        var autoplay: Bool = true
        /// Pauses the video while the system asks for reduced motion.
        ///
        /// Off by default, deliberately. Honouring the setting silently made the
        /// whole feature look broken on a machine that has it on: the video was
        /// simply never played and nothing on screen said why. A background the
        /// user explicitly chose is also mostly hidden behind an opaque page, so
        /// it is closer to decoration than to an animation, which is the kind of
        /// thing the setting is normally about. It is a row in the pane rather
        /// than a silent override, and it says which way the system is set.
        var respectsReduceMotion: Bool = false
        var playbackSpeed: Double = 1
        var pauseWhenInactive: Bool = true
        var pauseWhenHidden: Bool = true
        /// Seconds into the video to start from.
        var startTime: Double = 0
        /// Shown until the first frame is ready, so a slow video is not a blank
        /// rectangle.
        var posterPath: String?
    }

    struct SolidFill: Codable, Equatable {
        var color: BackgroundColor = .init(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
    }

    struct Gradient: Codable, Equatable {
        enum Kind: String, Codable, CaseIterable, Identifiable {
            var id: String { rawValue }

            case linear, radial
            var title: String { self == .linear ? "Linear" : "Radial" }
        }

        struct Stop: Codable, Equatable, Identifiable {
            var id = UUID()
            var color: BackgroundColor
            /// 0...1 along the gradient.
            var location: Double

            init(id: UUID = UUID(), color: BackgroundColor, location: Double) {
                self.id = id
                self.color = color
                self.location = min(max(location, 0), 1)
            }
        }

        var kind: Kind = .linear
        /// Degrees, clockwise from pointing up. Linear only.
        var angle: Double = 90
        /// As a fraction of the window, 0...1. Radial only.
        var centerX: Double = 0.5
        var centerY: Double = 0.5
        /// As a fraction of the window's smaller side. Radial only.
        var startRadius: Double = 0
        var endRadius: Double = 0.75
        var stops: [Stop] = [
            Stop(color: .init(red: 0.16, green: 0.18, blue: 0.24, alpha: 1), location: 0),
            Stop(color: .init(red: 0.05, green: 0.05, blue: 0.07, alpha: 1), location: 1),
        ]

        var isUsable: Bool { stops.count >= 2 }
    }

    var kind: Kind = .none
    /// Local path. Stored as a string because the app is not sandboxed, so an
    /// `NSOpenPanel` URL needs no security-scoped bookmark. If it is ever
    /// sandboxed for the App Store this becomes bookmark data plus
    /// `com.apple.security.files.user-selected.read-only`.
    var path: String?
    var fit: Fit = .fill
    /// Used when `fit` is `.custom`. A percentage of the original size.
    var fitScale: Double = 100
    var repeatMode: Repeat = .none
    var position: Position = .center
    var customX = Axis()
    var customY = Axis()
    var effects = Effects()
    var video = VideoOptions()
    var solid = SolidFill()
    var gradient = Gradient()

    /// Lets pages be see-through so the media shows behind them.
    ///
    /// Off by default, and ignored entirely while `kind` is `.none`, which is
    /// what makes "None" mean the appearance from before this existed.
    var showThroughPages: Bool = false

    /// Whether anything needs drawing at all.
    var isActive: Bool {
        switch kind {
        case .none: false
        case .solid: true
        case .gradient: gradient.isUsable
        case .image, .video: !(path ?? "").isEmpty
        }
    }

    /// Whether a poster image has been chosen for the video renderer.
    ///
    /// It is the one thing the grading filters can reach when the background is a
    /// video, since only the poster is decoded as an image.
    var hasPoster: Bool { !(video.posterPath ?? "").isEmpty }

    /// Tile axis decisions, for the renderer.
    var repeatsHorizontally: Bool { repeatMode == .horizontal || repeatMode == .both }
    var repeatsVertically: Bool { repeatMode == .vertical || repeatMode == .both }

    /// Where the media sits for a given viewport, resolving the named or custom
    /// position. The media's size comes from `mediaSize(intrinsic:viewport:)`.
    func origin(ofSize size: NSSize, mediaSize: NSSize) -> CGPoint {
        switch position {
        case .topLeft: CGPoint(x: 0, y: size.height)
        case .topCenter: CGPoint(x: (size.width - mediaSize.width) / 2, y: size.height)
        case .topRight: CGPoint(x: size.width - mediaSize.width, y: size.height)
        case .centerLeft: CGPoint(x: 0, y: (size.height - mediaSize.height) / 2)
        case .center: CGPoint(
            x: (size.width - mediaSize.width) / 2,
            y: (size.height - mediaSize.height) / 2
        )
        case .centerRight: CGPoint(x: size.width - mediaSize.width, y: (size.height - mediaSize.height) / 2)
        case .bottomLeft: CGPoint(x: 0, y: 0)
        case .bottomCenter: CGPoint(x: (size.width - mediaSize.width) / 2, y: 0)
        case .bottomRight: CGPoint(x: size.width - mediaSize.width, y: 0)
        case .custom: CGPoint(
            x: customX.offset(in: size.width) - mediaSize.width / 2,
            y: customY.offset(in: size.height) - mediaSize.height / 2
        )
        }
    }

    /// The media's drawn size for the current fit.
    ///
    /// Geometry is passed in rather than stored: this type is the stored
    /// configuration, and the renderer's knowledge of the window and of the
    /// decoded image does not belong in a document.
    func mediaSize(intrinsic: NSSize, viewport: NSSize) -> NSSize {
        switch fit {
        case .original:
            return intrinsic
        case .contain, .fill:
            guard intrinsic.width > 0, intrinsic.height > 0,
                viewport.width > 0, viewport.height > 0
            else { return .zero }
            let scaleX = viewport.width / intrinsic.width
            let scaleY = viewport.height / intrinsic.height
            // Contain fits inside, fill covers: the smaller of the two ratios
            // versus the larger, which is the whole difference between them.
            let factor = fit == .contain ? min(scaleX, scaleY) : max(scaleX, scaleY)
            return NSSize(width: intrinsic.width * factor, height: intrinsic.height * factor)
        case .stretch:
            return viewport
        case .custom:
            let factor = min(max(fitScale, 1), 800) / 100
            return NSSize(width: intrinsic.width * factor, height: intrinsic.height * factor)
        }
    }

    /// The rectangle the media occupies, or `nil` when it tiles.
    func drawnRect(intrinsic: NSSize, viewport: NSSize) -> NSRect? {
        guard !repeatsHorizontally, !repeatsVertically else { return nil }
        let size = mediaSize(intrinsic: intrinsic, viewport: viewport)
        guard size.width > 0, size.height > 0 else { return nil }
        return NSRect(origin: origin(ofSize: viewport, mediaSize: size), size: size)
    }
}

/// An sRGB colour, stored as components because `NSColor` is not `Codable`.
///
/// The same reason `StoredNoise` keeps its tint as numbers, and it also means a
/// colour read back from a document is the colour that was picked rather than
/// whatever the current appearance calls "control accent".
struct BackgroundColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        // Converted on the way in: an `NSColor` in a calibrated or catalog space
        // would otherwise be read back through a different space and drift.
        let resolved = color.usingColorSpace(.sRGB) ?? color
        self.red = Double(resolved.redComponent)
        self.green = Double(resolved.greenComponent)
        self.blue = Double(resolved.blueComponent)
        self.alpha = Double(resolved.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(min(max(red, 0), 1)),
            green: CGFloat(min(max(green, 0), 1)),
            blue: CGFloat(min(max(blue, 0), 1)),
            alpha: CGFloat(min(max(alpha, 0), 1))
        )
    }

    /// Hex for the settings pane, since that is how people recognise a colour
    /// they picked. Returns `#rrggbb` or `#rrggbbaa`.
    var hexString: String {
        let component = { (value: Double) in
            let scaled = Int((min(max(value, 0), 1) * 255).rounded())
            return String(format: "%02x", scaled)
        }
        let base = "#" + component(red) + component(green) + component(blue)
        guard alpha < 0.999 else { return base }
        return base + component(alpha)
    }
}