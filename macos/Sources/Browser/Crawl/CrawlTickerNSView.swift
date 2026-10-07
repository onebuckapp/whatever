import AppKit

/// Input bundle for the crawl ticker view. `fontSize` is already scaled for
/// Dynamic Type by the SwiftUI wrapper; everything here is in points.
struct CrawlTickerInputs {
    var headlines: [CrawlHeadline]
    var speed: Double
    var direction: AppSettings.CrawlDirection
    var fontSize: Double
    var backgroundOpacity: Double
    var favicons: [String: NSImage]
}

/// The scrolling headline strip, layer-hosted.
///
/// The strip bitmap comes from `CrawlStripRenderer` and is drawn exactly once
/// per content change. Scrolling is one infinite `CABasicAnimation` on a
/// single layer's `position.x`, so the per-frame work is a texture shift done
/// by the render server: ~0% CPU, versus ~40% for the old hundreds-of-live-
/// views SwiftUI strip this replaces.
///
/// Structure: root → background pill + content container (gradient-masked,
/// inset 12pt like the old padded row) → one strip layer holding the bitmap.
/// The bitmap always covers the visible width plus one full pass, and the
/// animation spans exactly one pass width, so the wrap is seamless in both
/// directions.
final class CrawlTickerNSView: NSView {
    /// Horizontal inset of the scrolling content, matching the old row's
    /// `.padding(.horizontal, 12)`.
    static let horizontalInset: CGFloat = 12
    /// Backing scale of the strip bitmap. Fixed at 2x: the bitmap always
    /// carries twice the displayed points, then renders at half size, so text
    /// stays Retina-sharp no matter which screen the window is on — or
    /// whether the view even has a window yet at first render. Downsampling
    /// on 1x displays stays sharp; memory stays bounded by the renderer's
    /// point-width cap.
    static let stripScale: CGFloat = 2
    private static let loopKey = "crawlLoop"

    var onOpen: ((URL) -> Void)?
    /// Test hook fired when a loop actually launches, with the pass width and
    /// the full-pass duration. Nil in production.
    var onLoopStart: ((CGFloat, TimeInterval) -> Void)?
    /// When false the strip stays parked at the loop start for deterministic
    /// snapshots. Tests use this; production always animates.
    var animateLoop = true

    private var inputs = CrawlTickerInputs(
        headlines: [], speed: 60, direction: .rightToLeft,
        fontSize: 12, backgroundOpacity: 0.85, favicons: [:]
    )
    private var strip: CrawlStrip?
    /// Model offset: the strip layer's left edge in container coordinates.
    /// Always inside one wrap segment once a strip exists.
    private var offsetX: CGFloat = 0
    /// Last halt state applied through `setHalted`, so the wrapper only
    /// drives transitions instead of re-pausing every update.
    private(set) var isHalted = false
    /// Appearance the current bitmap was baked in; label colors resolve at
    /// draw time, so an appearance change must re-render.
    private var lastAppearanceName: String = ""

    private let rootLayer = CALayer()
    private let backgroundLayer = CALayer()
    private let containerLayer = CALayer()
    private let maskLayer = CAGradientLayer()
    private let stripLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: no AppKit backing store, no implicit view drawing.
        // Every pixel is managed CALayers below.
        layer = rootLayer
        wantsLayer = true
        // Fixed 2x on every layer: layer-hosting views get no automatic
        // contentsScale management, and anything rasterized at 1x (the pill,
        // its border, the strip) would upscale softly on Retina.
        rootLayer.contentsScale = Self.stripScale
        backgroundLayer.contentsScale = Self.stripScale
        containerLayer.contentsScale = Self.stripScale
        maskLayer.contentsScale = Self.stripScale
        stripLayer.contentsScale = Self.stripScale
        backgroundLayer.cornerRadius = 8
        backgroundLayer.borderWidth = 1
        rootLayer.addSublayer(backgroundLayer)
        containerLayer.mask = maskLayer
        maskLayer.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        maskLayer.locations = [0, 0.05, 0.95, 1]
        maskLayer.startPoint = CGPoint(x: 0, y: 0.5)
        maskLayer.endPoint = CGPoint(x: 1, y: 0.5)
        rootLayer.addSublayer(containerLayer)
        stripLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        containerLayer.addSublayer(stripLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Inputs

    /// Pushes fresh inputs. Re-renders only when the strip content (or the
    /// appearance its colors bake in) actually changed, and restarts the loop
    /// only when the loop inputs changed; opacity only touches the background
    /// pill. Backing scale never invalidates: the bitmap is always 2x.
    func update(with newInputs: CrawlTickerInputs) {
        let old = inputs
        inputs = newInputs
        updateBackground()
        let appearanceName = effectiveAppearance.name.rawValue
        let contentChanged = newInputs.headlines != old.headlines
            || newInputs.fontSize != old.fontSize
            || !faviconsEqual(newInputs.favicons, old.favicons)
            || appearanceName != lastAppearanceName
        if contentChanged || !coversVisibleWidth {
            renderStrip()
        } else if newInputs.speed != old.speed || newInputs.direction != old.direction {
            startLoop(fromStart: true)
        }
    }

    /// Freezes (`true`) or resumes from the leading edge (`false`) the loop,
    /// mirroring the old `haltLoop` contract the bar controller drives around
    /// teardown: no animation is ever live while the bar leaves the
    /// hierarchy, and re-showing restarts cleanly.
    func setHalted(_ halt: Bool) {
        isHalted = halt
        if halt {
            pauseLoop()
        } else {
            startLoop(fromStart: true)
        }
    }

    /// Re-renders the strip bitmap, preserving the loop's completed fraction
    /// so icon pop-ins and feed refreshes glide instead of jumping back to
    /// the leading edge.
    private func renderStrip() {
        let appearance = effectiveAppearance
        lastAppearanceName = appearance.name.rawValue
        // Fraction of the current wrap segment already shown, so the new
        // strip resumes from the same story, not the same pixels.
        let wasAnimating = isLooping
        let fraction = loopFraction
        var rendered: CrawlStrip?
        appearance.performAsCurrentDrawingAppearance {
            rendered = CrawlStripRenderer.render(
                headlines: inputs.headlines,
                fontSize: inputs.fontSize,
                favicons: inputs.favicons,
                scale: Self.stripScale,
                coverWidth: max(1, containerLayer.bounds.width)
            )
        }
        strip = rendered
        guard let strip else {
            stripLayer.contents = nil
            stripLayer.removeAnimation(forKey: Self.loopKey)
            needsDisplay = false
            return
        }
        stripLayer.contents = strip.cgImage
        stripLayer.contentsScale = strip.scale
        stripLayer.bounds = CGRect(origin: .zero, size: strip.size)
        // The segment runs 0 → -W right-to-left and -W → 0 left-to-right,
        // so progress subtracts for RTL and adds for LTR.
        let sign: CGFloat = inputs.direction == .rightToLeft ? -1 : 1
        offsetX = segmentStart(for: strip.passWidth) + sign * fraction * strip.passWidth
        layoutStrip()
        window?.invalidateCursorRects(for: self)
        if wasAnimating && animateLoop && !isHalted {
            startLoop(fromStart: false)
        } else if animateLoop, !isHalted {
            startLoop(fromStart: true)
        } else {
            pauseLoop()
        }
        invalidateAccessibility()
    }

    // MARK: - Loop

    /// Whether the infinite scroll animation is currently installed.
    var isLooping: Bool { stripLayer.animation(forKey: Self.loopKey) != nil }

    // MARK: - Test hooks

    /// Model offset (strip layer's left edge in container coordinates).
    var currentOffsetForTesting: CGFloat { offsetX }
    var stripForTesting: CrawlStrip? { strip }
    var loopAnimationForTesting: CABasicAnimation? {
        stripLayer.animation(forKey: Self.loopKey) as? CABasicAnimation
    }
    var presentationOffsetForTesting: CGFloat? {
        stripLayer.presentation()?.position.x
    }    /// Strip layer center in container coordinates. The y half must sit at
    /// the container mid-height: vertical centering by construction.
    var stripCenterForTesting: CGPoint { stripLayer.position }

    /// Steps the loop forward by `seconds` and returns the resulting
    /// presented offset. Re-installs a copy of the in-flight animation with
    /// its start rewound by `seconds`: the loop then reads that much further
    /// along, no wall-clock needed (headless sessions have no render server
    /// ticking). Test-only; leaves the stepped loop in place.
    func stepLoopForTesting(seconds: TimeInterval) -> CGFloat? {
        guard let animation = stripLayer.animation(forKey: Self.loopKey)?.copy() as? CABasicAnimation
        else { return nil }
        animation.beginTime = CACurrentMediaTime() - seconds
        stripLayer.add(animation, forKey: Self.loopKey)
        CATransaction.flush()
        return stripLayer.presentation()?.position.x
    }

    /// Starts (or restarts) the loop. From the leading edge by default;
    /// resuming from the preserved offset after a re-render keeps the motion
    /// continuous.
    func startLoop(fromStart: Bool) {
        guard animateLoop, !isHalted, let strip, strip.passWidth > 0 else { return }
        let speed = max(1, inputs.speed)
        if fromStart {
            offsetX = segmentStart(for: strip.passWidth)
        }
        let end = segmentEnd(for: strip.passWidth, from: offsetX)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripLayer.position.x = offsetX
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = offsetX
        animation.toValue = end
        animation.duration = TimeInterval(abs(end - offsetX) / speed)
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.repeatCount = .infinity
        stripLayer.add(animation, forKey: Self.loopKey)
        onLoopStart?(strip.passWidth, TimeInterval(strip.passWidth / speed))
    }

    /// Freezes the loop, keeping the current spot in the model so a later
    /// resume continues instead of jumping.
    func pauseLoop() {
        if let presentation = stripLayer.presentation() {
            offsetX = presentation.position.x
        }
        stripLayer.removeAnimation(forKey: Self.loopKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripLayer.position.x = offsetX
        CATransaction.commit()
    }

    /// Completed fraction of the current wrap segment, 0 when parked. Used to
    /// carry loop progress across re-renders.
    private var loopFraction: Double {
        guard let strip, strip.passWidth > 0 else { return 0 }
        let current = isLooping ? (stripLayer.presentation()?.position.x ?? offsetX) : offsetX
        let start = segmentStart(for: strip.passWidth)
        if inputs.direction == .rightToLeft {
            return Double(min(1, max(0, (start - current) / strip.passWidth)))
        } else {
            return Double(min(1, max(0, (current - start) / strip.passWidth)))
        }
    }

    private func segmentStart(for passWidth: CGFloat) -> CGFloat {
        inputs.direction == .rightToLeft ? 0 : -passWidth
    }

    private func segmentEnd(for passWidth: CGFloat, from: CGFloat) -> CGFloat {
        inputs.direction == .rightToLeft ? from - passWidth : from + passWidth
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Snap frames to the 2x pixel grid: a layer sitting on a fractional
        // boundary resamples everything it carries, which reads as blur.
        // Widths keep their 0.5pt values (pixel-aligned at 2x); only
        // quarter-point dust is removed, so coverage math is unaffected.
        rootLayer.frame = Self.snapped(bounds)
        backgroundLayer.frame = Self.snapped(bounds)
        updateBackground()
        containerLayer.frame = Self.snapped(bounds.insetBy(dx: Self.horizontalInset, dy: 0))
        maskLayer.frame = containerLayer.bounds
        // A wider window may outgrow the bitmap's spare pass; shrinking never
        // does. Content changes re-render through `update(with:)`.
        if !coversVisibleWidth, strip != nil {
            renderStrip()
        } else {
            layoutStrip()
        }
    }

    /// The bitmap covers the visible width plus one wrap pass; only growing
    /// past that spare triggers a re-render.
    private var coversVisibleWidth: Bool {
        guard let strip else { return false }
        return containerLayer.bounds.width + strip.passWidth <= strip.size.width + 0.5
    }

    /// Positions the strip layer: vertically centered in the bar (by
    /// construction, not font metrics) at the model offset. The y lands on
    /// the pixel grid so the texture never resamples statically; x stays
    /// fractional by design — that is the smooth scroll.
    private func layoutStrip() {
        guard let strip else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripLayer.position = CGPoint(
            x: offsetX,
            y: Self.snap(containerLayer.bounds.height / 2)
        )
        stripLayer.bounds = CGRect(origin: .zero, size: strip.size)
        CATransaction.commit()
    }

    /// Rounds a point value to the 2x pixel grid.
    static func snap(_ value: CGFloat) -> CGFloat {
        (value * stripScale).rounded() / stripScale
    }

    /// Snaps a rect's origin and size to the 2x pixel grid.
    static func snapped(_ rect: CGRect) -> CGRect {
        CGRect(
            x: snap(rect.origin.x), y: snap(rect.origin.y),
            width: snap(rect.width), height: snap(rect.height)
        )
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backgroundLayer.backgroundColor = NSColor.controlBackgroundColor
                .withAlphaComponent(inputs.backgroundOpacity).cgColor
            backgroundLayer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
        // Label/secondary colors bake into the bitmap: re-render frozen.
        renderStrip()
    }

    private func faviconsEqual(_ a: [String: NSImage], _ b: [String: NSImage]) -> Bool {
        guard a.keys == b.keys else { return false }
        return a.keys.allSatisfy { a[$0] === b[$0] }
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let strip else { return }
        let current = stripLayer.presentation()?.position.x ?? offsetX
        let stripX = (point.x - Self.horizontalInset) - current
        guard let headline = CrawlStripRenderer.headline(at: stripX, strip: strip),
              let url = URL(string: headline.url)
        else { return }
        onOpen?(url)
    }

    override func resetCursorRects() {
        discardCursorRects()
        if strip != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Headline ticker" }

    override func accessibilityChildren() -> [Any]? {
        guard let strip, let window else { return nil }
        let current = stripLayer.presentation()?.position.x ?? offsetX
        let stripY = (containerLayer.bounds.height - strip.size.height) / 2
        return strip.items.compactMap { item -> NSAccessibilityElement? in
            var rect = item.frame
            rect.origin.x += Self.horizontalInset + current
            rect.origin.y += stripY
            let windowRect = convert(rect, to: nil)
            guard windowRect.intersects(bounds) else { return nil }
            let element = CrawlTickerAXElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.link)
            element.setAccessibilityLabel(
                CrawlContent.itemText(site: item.headline.site, title: item.headline.title)
            )
            element.setAccessibilityFrame(window.convertToScreen(windowRect))
            element.pressHandler = { [weak self] in
                guard let url = URL(string: item.headline.url) else { return }
                self?.onOpen?(url)
            }
            return element
        }
    }

    private func invalidateAccessibility() {
        NSAccessibility.post(
            element: self,
            notification: .layoutChanged
        )
    }
}

/// One headline link inside the ticker for assistive tech, replacing the old
/// per-item SwiftUI link traits.
private final class CrawlTickerAXElement: NSAccessibilityElement {
    var pressHandler: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        pressHandler?()
        return true
    }
}
