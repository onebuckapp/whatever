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
    /// Item separator mark, normalized at the render site.
    var separator: String
}

/// The scrolling headline strip, layer-hosted.
///
/// The strip bitmap comes from `CrawlStripRenderer` and is drawn exactly once
/// per content change. Scrolling is one infinite stepped keyframe animation
/// on a
/// single layer's `position.x`, so the per-frame work is a texture shift done
/// by the render server: ~0% CPU, versus ~40% for the old hundreds-of-live-
/// views SwiftUI strip this replaces.
///
/// Structure: root → background pill + content container (gradient-masked,
/// inset 12pt like the old padded row) → one strip layer holding the bitmap.
/// The bitmap always covers the visible width plus one full pass, and the
/// loop sweeps the bitmap's full span, reversing at each end instead of
/// wrapping, so the bar never shows a half-empty strip.
final class CrawlTickerNSView: NSView {
    /// Horizontal inset of the scrolling content, matching the old row's
    /// `.padding(.horizontal, 12)`.
    static let horizontalInset: CGFloat = 12
    /// Backing scale of the strip bitmap. Follows the window: Retina gets a
    /// 2x bitmap, a 1x display gets a native 1x one. A fixed 2x everywhere
    /// would force the compositor to downsample on 1x screens, which reads
    /// as permanent blur no raster grid can fix. Windowless (tests, first
    /// render before attach) falls back to 2.
    private var currentScale: CGFloat {
        max(1, window?.backingScaleFactor ?? 2)
    }
    private static let loopKey = "crawlLoop"

    var onOpen: ((URL) -> Void)?
    /// Test hook fired when a loop actually launches, with the sweep span
    /// and the one-way duration. Nil in production.
    var onLoopStart: ((CGFloat, TimeInterval) -> Void)?
    /// When false the strip stays parked at the loop start for deterministic
    /// snapshots. Tests use this; production always animates.
    var animateLoop = true

    private var inputs = CrawlTickerInputs(
        headlines: [], speed: 60, direction: .rightToLeft,
        fontSize: 12, backgroundOpacity: 0.85, favicons: [:],
        separator: CrawlContent.defaultSeparator
    )
    private var strip: CrawlStrip? { tiles.first }
    /// One bitmap per tile, each no wider than the renderer's tile cap, laid
    /// edge to edge. A giant strip at a large font is many textures, never
    /// one shrunk bitmap.
    private var tiles: [CrawlStrip] = []
    /// One layer per tile above, kept in lockstep: same sweep values shifted
    /// by each tile's offset.
    private var stripLayers: [CALayer] = []
    /// Model offset: the strip layer's left edge in container coordinates.
    /// Always inside one wrap segment once a strip exists.
    private var offsetX: CGFloat = 0
    /// Last halt state applied through `setHalted`, so the wrapper only
    /// drives transitions instead of re-pausing every update.
    private(set) var isHalted = false
    /// Sweep span the in-flight animation covers, for resize healing.
    private var loopTravel: CGFloat = 0
    /// Guards resume-leg completions: any pause or restart retires the
    /// pending one, so a stale completion can never resurrect the loop.
    private var resumeToken = 0
    /// Appearance the current bitmap was baked in; label colors resolve at
    /// draw time, so an appearance change must re-render.
    private var lastAppearanceName: String = ""

    private let rootLayer = CALayer()
    private let backgroundLayer = CALayer()
    private let containerLayer = CALayer()
    private let maskLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: no AppKit backing store, no implicit view drawing.
        // Every pixel is managed CALayers below.
        layer = rootLayer
        wantsLayer = true
        // Layer-hosting views get no automatic contentsScale management, and
        // anything rasterized at the wrong scale (the pill, its border, the
        // strip) would resample softly. Windowless for now, so the 2x
        // fallback; attaching corrects through `refreshScale`.
        rootLayer.contentsScale = currentScale
        backgroundLayer.contentsScale = currentScale
        containerLayer.contentsScale = currentScale
        maskLayer.contentsScale = currentScale
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
    }

    /// One scrolling texture layer: the bitmap at its tile offset, anchored
    /// by its left edge so positions read as left edges everywhere.
    private func makeStripLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsScale = currentScale
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        containerLayer.addSublayer(layer)
        return layer
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Inputs

    /// Pushes fresh inputs. Re-renders only when the strip content (or the
    /// appearance its colors bake in) actually changed, and restarts the loop
    /// only when the loop inputs changed; opacity only touches the background
    /// pill. A scale change re-renders through the backing-properties hook
    /// below, not here.
    func update(with newInputs: CrawlTickerInputs) {
        let old = inputs
        inputs = newInputs
        updateBackground()
        let appearanceName = effectiveAppearance.name.rawValue
        let contentChanged = newInputs.headlines != old.headlines
            || newInputs.fontSize != old.fontSize
            || !faviconsEqual(newInputs.favicons, old.favicons)
            || CrawlContent.normalizedSeparator(newInputs.separator)
                != CrawlContent.normalizedSeparator(old.separator)
            || appearanceName != lastAppearanceName
        if contentChanged || !coversVisibleWidth {
            renderStrip()
        } else if newInputs.speed != old.speed || newInputs.direction != old.direction {
            startLoop(fromStart: true)
        }
        // Backstop: if the loop should run but doesn't (a coalesced push, a
        // start that landed while detached), heal it here rather than
        // parking silently until the next settings nudge.
        ensureLoopState()
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
        var rendered: [CrawlStrip]?
        appearance.performAsCurrentDrawingAppearance {
            rendered = CrawlStripRenderer.renderTiles(
                headlines: inputs.headlines,
                fontSize: inputs.fontSize,
                favicons: inputs.favicons,
                scale: currentScale,
                coverWidth: max(1, containerLayer.bounds.width),
                separator: inputs.separator
            )
        }
        tiles = rendered ?? []
        syncStripLayers()
        guard !tiles.isEmpty else {
            needsDisplay = false
            return
        }
        for (layer, tile) in zip(stripLayers, tiles) {
            layer.contents = tile.cgImage
            layer.contentsScale = tile.scale
            layer.bounds = CGRect(origin: .zero, size: tile.size)
        }
        offsetX = endPreservingFraction(fraction, travel: currentTravel())
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

    /// One texture layer per tile, reusing layers across re-renders. Surplus
    /// layers leave the hierarchy; a fresh render never rebuilds what it can
    /// refill.
    private func syncStripLayers() {
        while stripLayers.count < tiles.count {
            stripLayers.append(makeStripLayer())
        }
        while stripLayers.count > tiles.count {
            stripLayers.removeLast().removeFromSuperlayer()
        }
        for layer in stripLayers {
            layer.removeAnimation(forKey: Self.loopKey)
        }
    }

    // MARK: - Loop

    /// Whether the infinite scroll animation is currently installed.
    var isLooping: Bool {
        stripLayers.first?.animation(forKey: Self.loopKey) != nil
    }

    // MARK: - Test hooks

    /// Model offset (strip layer's left edge in container coordinates).
    var currentOffsetForTesting: CGFloat { offsetX }
    var stripForTesting: CrawlStrip? { strip }
    var loopAnimationForTesting: CAKeyframeAnimation? {
        stripLayers.first?.animation(forKey: Self.loopKey) as? CAKeyframeAnimation
    }
    /// Strip layer center in container coordinates. The y half must sit at
    /// the container mid-height: vertical centering by construction.
    var stripCenterForTesting: CGPoint { stripLayers.first?.position ?? .zero }

    /// Steps the loop forward by `seconds` and returns the resulting
    /// presented offset. Re-installs a copy of the in-flight animation with
    /// its start rewound by `seconds`: the loop then reads that much further
    /// along, no wall-clock needed (headless sessions have no render server
    /// ticking). Test-only; leaves the stepped loop in place.
    func stepLoopForTesting(seconds: TimeInterval) -> CGFloat? {
        guard let first = stripLayers.first,
              first.animation(forKey: Self.loopKey) != nil
        else { return nil }
        // Rewind each layer's own animation: values carry per-tile offsets
        // and must not be swapped between layers.
        for layer in stripLayers {
            guard let animation = layer.animation(forKey: Self.loopKey)?.copy() as? CAKeyframeAnimation
            else { return nil }
            animation.beginTime = CACurrentMediaTime() - seconds
            layer.add(animation, forKey: Self.loopKey)
        }
        CATransaction.flush()
        return first.presentation()?.position.x
    }

    /// Starts (or restarts) the loop. From the leading edge by default; from
    /// the preserved offset after a re-render, gliding through icon pop-ins
    /// and feed refreshes instead of jumping back to the start.
    func startLoop(fromStart: Bool) {
        guard animateLoop, !isHalted, strip != nil else { return }
        let travel = currentTravel()
        guard travel > 0 else {
            // The whole strip fits on screen: park at the leading edge with
            // no animation. Coverage is total by construction, never gappy.
            for layer in stripLayers {
                layer.removeAnimation(forKey: Self.loopKey)
            }
            offsetX = travelStart(travel)
            snapModel()
            return
        }
        resumeToken += 1
        let token = resumeToken
        loopTravel = travel
        let speed = max(1, inputs.speed)
        if fromStart {
            offsetX = travelStart(travel)
        }
        let end = travelEnd(travel)
        if offsetX == travelStart(travel) {
            installPingPong(from: offsetX, to: end, speed: speed)
        } else {
            // Resume mid-sweep with a single leg to the turn, then bounce:
            // autoreverse repeats its own from/to, so a bounce can only
            // ever start from an endpoint.
            installLeg(from: offsetX, to: end, speed: speed) { [weak self] in
                guard let self, token == self.resumeToken,
                      self.animateLoop, !self.isHalted, self.strip != nil
                else { return }
                let turnTravel = self.currentTravel()
                self.offsetX = self.travelEnd(turnTravel)
                self.loopTravel = turnTravel
                self.installPingPong(
                    from: self.offsetX, to: self.travelStart(turnTravel),
                    speed: max(1, self.inputs.speed)
                )
            }
        }
        onLoopStart?(travel, TimeInterval(travel / speed))
    }

    /// The infinite bounce: sweeps the full span, then reverses at each end
    /// instead of wrapping, so the bar is never half-empty.
    ///
    /// The sweep is stepped in half-point increments (one backing pixel)
    /// with discrete calculation: the render server holds each value
    /// instead of interpolating, so the texture is never sampled between
    /// pixels mid-flight. A continuous interpolation would resample every
    /// frame and read as permanent motion blur, which no raster grid can
    /// fix.
    private func installPingPong(from: CGFloat, to: CGFloat, speed: Double) {
        guard !tiles.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, tile) in zip(stripLayers, tiles) {
            layer.position.x = from + tile.offset
        }
        CATransaction.commit()
        for (layer, tile) in zip(stripLayers, tiles) {
            let animation = CAKeyframeAnimation(keyPath: "position.x")
            animation.values = steppedValues(
                from: from + tile.offset, to: to + tile.offset)
            animation.calculationMode = .discrete
            animation.duration = TimeInterval(abs(to - from) / speed)
            animation.autoreverses = true
            animation.repeatCount = .infinity
            layer.add(animation, forKey: Self.loopKey)
        }
    }

    /// Sweep values snapped to the pixel grid, stepping one backing pixel
    /// at a time. Consecutive duplicates after snapping are harmless: the
    /// hold just lasts one step longer.
    private func steppedValues(from: CGFloat, to: CGFloat) -> [CGFloat] {
        let pixel = 1 / currentScale
        let steps = max(1, Int(ceil(abs(to - from) / pixel)))
        return (0...steps).map { i in
            snap(from + (to - from) * CGFloat(i) / CGFloat(steps))
        }
    }

    /// One sweep, then `completion`. The end state holds instead of snapping
    /// back, so handing off to the bounce is seamless.
    private func installLeg(
        from: CGFloat, to: CGFloat, speed: Double,
        completion: @escaping () -> Void
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, tile) in zip(stripLayers, tiles) {
            layer.position.x = from + tile.offset
        }
        CATransaction.commit()
        // The handoff completion fires once: it belongs to the lead tile,
        // whose sweep the model follows.
        var isFirst = true
        for (layer, tile) in zip(stripLayers, tiles) {
            let animation = CAKeyframeAnimation(keyPath: "position.x")
            animation.values = steppedValues(
                from: from + tile.offset, to: to + tile.offset)
            animation.calculationMode = .discrete
            animation.duration = TimeInterval(abs(to - from) / speed)
            animation.isRemovedOnCompletion = false
            animation.fillMode = .forwards
            if isFirst {
                isFirst = false
                CATransaction.begin()
                CATransaction.setCompletionBlock(completion)
                layer.add(animation, forKey: Self.loopKey)
                CATransaction.commit()
            } else {
                layer.add(animation, forKey: Self.loopKey)
            }
        }
    }

    /// Freezes the loop, keeping the current spot in the model so a later
    /// resume continues instead of jumping.
    func pauseLoop() {
        resumeToken += 1
        if let presentation = stripLayers.first?.presentation() {
            // Snapped: the model only ever feeds pixel-grid values, so a
            // resume starts exactly where the pause parked.
            offsetX = snap(presentation.position.x)
        }
        for layer in stripLayers {
            layer.removeAnimation(forKey: Self.loopKey)
        }
        snapModel()
    }

    private func snapModel() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, tile) in zip(stripLayers, tiles) {
            layer.position.x = offsetX + tile.offset
        }
        CATransaction.commit()
    }

    /// Starts the loop when it should run but doesn't. The backstop behind
    /// every entry point: enabling the bar, re-attaching it, or any update
    /// heals a missed start instead of parking silently.
    private func ensureLoopState() {
        guard animateLoop, !isHalted, strip != nil, !isLooping else { return }
        startLoop(fromStart: false)
    }

    /// Completed fraction of the current sweep, 0 when parked. Used to carry
    /// loop progress across re-renders and resizes.
    private var loopFraction: Double {
        guard loopTravel > 0 else { return 0 }
        let lead = stripLayers.first?.presentation()?.position.x ?? offsetX
        let current = isLooping ? lead : offsetX
        let start = travelStart(loopTravel)
        let done: CGFloat
        if inputs.direction == .rightToLeft {
            done = start - current
        } else {
            done = current - start
        }
        return Double(min(1, max(0, done / loopTravel)))
    }

    private func containerWidth() -> CGFloat { containerLayer.bounds.width }

    /// Sweep span: all tiles edge to edge minus the visible width. Zero
    /// means the whole strip fits on screen and nothing moves.
    private func currentTravel() -> CGFloat {
        max(0, totalTilesWidth() - containerWidth())
    }

    /// The tiles laid edge to edge, in points.
    private func totalTilesWidth() -> CGFloat {
        guard let last = tiles.last else { return 0 }
        return last.offset + last.size.width
    }

    private func travelStart(_ travel: CGFloat) -> CGFloat {
        inputs.direction == .rightToLeft ? 0 : -travel
    }

    private func travelEnd(_ travel: CGFloat) -> CGFloat {
        inputs.direction == .rightToLeft ? -travel : 0
    }

    /// Maps a completed fraction onto a fresh span, direction-aware: the
    /// sweep runs 0 → −travel right-to-left and −travel → 0 left-to-right.
    private func endPreservingFraction(_ fraction: Double, travel: CGFloat) -> CGFloat {
        let sign: CGFloat = inputs.direction == .rightToLeft ? -1 : 1
        return travelStart(travel) + sign * CGFloat(fraction) * travel
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Snap frames to the backing pixel grid: a layer sitting on a
        // fractional boundary resamples everything it carries, which reads
        // as blur. Only sub-pixel dust is removed, so coverage math is
        // unaffected.
        rootLayer.frame = snapped(bounds)
        backgroundLayer.frame = snapped(bounds)
        updateBackground()
        containerLayer.frame = snapped(bounds.insetBy(dx: Self.horizontalInset, dy: 0))
        maskLayer.frame = containerLayer.bounds
        // A wider window may outgrow the bitmap's spare pass; shrinking never
        // does. Content changes re-render through `update(with:)`.
        if !coversVisibleWidth, strip != nil {
            renderStrip()
        } else {
            // A resized bar changes the sweep span: carry progress onto the
            // fresh span instead of turning around at a stale edge (or past
            // the bitmap, which would flash empty). Height-only changes keep
            // their span and skip this entirely.
            if strip != nil, isLooping {
                let newTravel = currentTravel()
                if abs(newTravel - loopTravel) > 0.5 {
                    let fraction = loopFraction
                    offsetX = endPreservingFraction(fraction, travel: newTravel)
                    startLoop(fromStart: false)
                }
            }
            layoutStrip()
        }
        ensureLoopState()
    }

    /// The tiles cover the visible width plus one wrap pass; only growing
    /// past that spare triggers a re-render.
    private var coversVisibleWidth: Bool {
        guard let strip else { return false }
        return containerLayer.bounds.width + strip.passWidth <= totalTilesWidth() + 0.5
    }

    /// Positions the tile layers: vertically centered in the bar (by
    /// construction, not font metrics) at the model offset plus each tile's
    /// own offset. The y lands on the pixel grid so no texture resamples
    /// statically; x steps on the grid through the loop animation.
    private func layoutStrip() {
        guard !tiles.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let y = snap(containerLayer.bounds.height / 2)
        for (layer, tile) in zip(stripLayers, tiles) {
            layer.position = CGPoint(x: offsetX + tile.offset, y: y)
            layer.bounds = CGRect(origin: .zero, size: tile.size)
        }
        CATransaction.commit()
    }

    /// Rounds a point value to the backing pixel grid.
    private func snap(_ value: CGFloat) -> CGFloat {
        (value * currentScale).rounded() / currentScale
    }

    /// Snaps a rect's origin and size to the backing pixel grid.
    private func snapped(_ rect: CGRect) -> CGRect {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Every show path ends here: (re-)attaching is where a loop added
        // while detached starts ticking, so enabling the bar scrolls
        // automatically with no settings nudge.
        if window != nil {
            refreshScale()
            ensureLoopState()
        }
    }

    /// The window moved across displays or the display scale changed: adopt
    /// the new backing scale on every layer and re-render the strip for it.
    /// A bitmap baked for another scale would upscale or downsample here,
    /// which reads as blur.
    private var lastScale: CGFloat = 2

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshScale()
    }

    private func refreshScale() {
        let scale = currentScale
        rootLayer.contentsScale = scale
        backgroundLayer.contentsScale = scale
        containerLayer.contentsScale = scale
        maskLayer.contentsScale = scale
        for layer in stripLayers {
            layer.contentsScale = scale
        }
        guard scale != lastScale else { return }
        lastScale = scale
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
        let current = stripLayers.first?.presentation()?.position.x ?? offsetX
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
        let current = stripLayers.first?.presentation()?.position.x ?? offsetX
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
