import AppKit
import QuartzCore
import Testing
@testable import Whatever

/// Proves the crawl strip rasterizes headline content and scrolls it on the
/// GPU, without a window.
///
/// The bar's performance story is that the strip is drawn once per content
/// change (`CrawlStripRenderer`) and then moved as a single texture by one
/// infinite `CABasicAnimation`. These tests pin both halves: the bitmap
/// carries real ink at full ideal width (never squeezed), and the view owns
/// exactly one linear loop animation that advances wall-clock time with no
/// per-frame view work.
struct CrawlTickerRenderTests {
    private func sampleHeadlines() -> [CrawlHeadline] {
        [
            CrawlHeadline(
                articleID: 1, site: "website.com", title: "Lorem ipsum dolor sit amet",
                url: "https://website.com/a", feedURL: "https://website.com/feed", publishedAt: 2
            ),
            CrawlHeadline(
                articleID: 2, site: "website.org", title: "Something is happening",
                url: "https://website.org/b", feedURL: "https://website.com/feed", publishedAt: 1
            ),
        ]
    }

    private func sampleInputs() -> CrawlTickerInputs {
        CrawlTickerInputs(
            headlines: sampleHeadlines(),
            speed: 60,
            direction: .rightToLeft,
            fontSize: 12,
            backgroundOpacity: 0.85,
            favicons: [:],
            separator: "|"
        )
    }

    private func render(
        _ headlines: [CrawlHeadline],
        fontSize: CGFloat = 12,
        favicons: [String: NSImage] = [:],
        coverWidth: CGFloat = 800,
        separator: String = "|"
    ) -> CrawlStrip? {
        CrawlStripRenderer.render(
            headlines: headlines, fontSize: fontSize,
            favicons: favicons, scale: 2, coverWidth: coverWidth,
            separator: separator
        )
    }

    /// Nonzero bytes in the bitmap. The background stays transparent (zeros),
    /// so any ink — text or icon — counts without caring about channel order.
    private func inkCount(_ strip: CrawlStrip) -> Int {
        guard let data = strip.bitmap.bitmapData else { return 0 }
        let count = strip.bitmap.pixelsWide * strip.bitmap.pixelsHigh
            * strip.bitmap.bitsPerPixel / 8
        var ink = 0
        for i in 0..<count where data[i] != 0 {
            ink += 1
        }
        return ink
    }

    private func makeView() -> CrawlTickerNSView {
        let view = CrawlTickerNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 28))
        view.update(with: sampleInputs())
        view.layout()
        return view
    }

    /// Hosts the view in a real (never shown) window so its layer tree is
    /// attached to a render context and Core Animation advances wall-clock
    /// time, like in the live app.
    private func makeWindowedView() -> (view: CrawlTickerNSView, window: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 28),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        let view = CrawlTickerNSView(frame: window.contentView!.bounds)
        view.update(with: sampleInputs())
        window.contentView?.addSubview(view)
        view.layout()
        return (view, window)
    }

    @Test("strip renders headline ink on a transparent background")
    func stripRendersInk() {
        guard let strip = render(sampleHeadlines()) else {
            Issue.record("renderer produced no strip")
            return
        }
        #expect(inkCount(strip) > 500, "no headline ink in the strip bitmap")
    }

    @Test("strip covers the visible width plus a wrap pass, never squeezed")
    func stripCoversVisibleWidth() {
        guard let strip = render(sampleHeadlines()) else {
            Issue.record("renderer produced no strip")
            return
        }
        #expect(strip.passWidth > 0, "degenerate wrap period")
        #expect(
            strip.size.width >= 800 + strip.passWidth - 1,
            "strip is \(strip.size.width)pt wide for an 800pt bar: content squeezed"
        )
    }

    @Test("empty headlines render no strip")
    func emptyRendersNil() {
        #expect(render([]) == nil, "empty headlines must render nothing")
    }

    @Test("larger font renders a taller strip")
    func fontSizeRerenders() {
        guard let small = render(sampleHeadlines(), fontSize: 12),
              let large = render(sampleHeadlines(), fontSize: 24)
        else {
            Issue.record("renderer produced no strip")
            return
        }
        #expect(large.size.height > small.size.height, "font size did not change the strip")
    }

    @Test("a cached favicon changes the rendered item")
    func faviconChangesPixels() {
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        guard let plain = render(sampleHeadlines()),
              let iconic = render(
                  sampleHeadlines(),
                  favicons: ["https://website.com/feed": icon]
              )
        else {
            Issue.record("renderer produced no strip")
            return
        }
        func bytes(_ strip: CrawlStrip) -> [UInt8] {
            guard let data = strip.bitmap.bitmapData else { return [] }
            let count = strip.bitmap.pixelsWide * strip.bitmap.pixelsHigh
                * strip.bitmap.bitsPerPixel / 8
            return (0..<count).map { data[$0] }
        }
        #expect(bytes(plain) != bytes(iconic), "favicon did not change the rendered item")
        // The icon replaces the site name, but the item still hit-tests.
        let first = iconic.items[0]
        let hit = CrawlStripRenderer.headline(at: first.frame.midX, strip: iconic)
        #expect(hit?.articleID == 1, "icon item no longer maps to its headline")
    }

    @Test("a custom separator changes the rendered strip")
    func separatorChangesPixels() {
        func bytes(separator: String) -> [UInt8] {
            guard let strip = render(sampleHeadlines(), separator: separator),
                  let data = strip.bitmap.bitmapData
            else { return [] }
            let count = strip.bitmap.pixelsWide * strip.bitmap.pixelsHigh
                * strip.bitmap.bitsPerPixel / 8
            return (0..<count).map { data[$0] }
        }
        #expect(bytes(separator: "|") != bytes(separator: "•"), "separator did not change the strip")
    }

    @Test("click mapping finds headlines, including across the wrap")
    func clickMapping() {
        guard let strip = render(sampleHeadlines()) else {
            Issue.record("renderer produced no strip")
            return
        }
        #expect(strip.items.count == 2, "expected one item per headline in the first pass")
        #expect(
            CrawlStripRenderer.headline(at: strip.items[1].frame.midX, strip: strip)?.articleID == 2,
            "second item did not map to its headline"
        )
        // One full pass over: identical content, identical hit.
        let wrapped = strip.items[0].frame.midX + strip.passWidth
        #expect(
            CrawlStripRenderer.headline(at: wrapped, strip: strip)?.articleID == 1,
            "wrapped coordinate did not map to the first headline"
        )
        #expect(CrawlStripRenderer.headline(at: -1, strip: strip) == nil, "negative x hit")
        #expect(
            CrawlStripRenderer.headline(at: strip.size.width, strip: strip) == nil,
            "past-the-end x hit"
        )
        // The delimiter gap between items belongs to no headline.
        let gap = (strip.items[0].frame.maxX + strip.items[1].frame.minX) / 2
        if strip.items[1].frame.minX - strip.items[0].frame.maxX > 2 {
            #expect(
                CrawlStripRenderer.headline(at: gap, strip: strip) == nil,
                "delimiter gap mapped to a headline"
            )
        }
    }

    @Test("view centers the strip vertically in a tall bar")
    @MainActor
    func viewCentersStrip() {
        let view = CrawlTickerNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(with: sampleInputs())
        view.layout()
        guard let strip = view.stripForTesting else {
            Issue.record("view rendered no strip")
            return
        }
        // The strip layer's center sits at the container mid-height: centered
        // by construction, independent of font metrics.
        let center = view.stripCenterForTesting
        #expect(abs(center.y - 20) <= 1, "strip center at y=\(center.y) in a 40pt bar")
        #expect(strip.size.height < 40, "strip taller than the bar")
    }

    @Test("exactly one stepped loop animation advances with layer time")
    @MainActor
    func loopAnimationMoves() {
        let (view, _) = makeWindowedView()
        view.startLoop(fromStart: true)
        #expect(view.isLooping, "no loop animation installed")
        guard let animation = view.loopAnimationForTesting else {
            Issue.record("loop animation missing")
            return
        }
        #expect(animation.repeatCount == .infinity, "loop does not repeat forever")
        #expect(animation.autoreverses, "loop wraps instead of bouncing at the ends")
        #expect(
            animation.calculationMode == .discrete,
            "loop interpolates: the texture would resample every frame"
        )
        // Stepped in half-point increments with the endpoints exact, so the
        // sweep covers the same span at the same speed, quantized.
        let values = animation.values as? [CGFloat] ?? []
        #expect(values.count >= 2, "loop has no sweep values")
        #expect(values.first == 0, "loop does not start at the leading edge")
        guard let strip = view.stripForTesting else {
            Issue.record("view rendered no strip")
            return
        }
        // One-way sweep duration: full bitmap span minus the visible width,
        // at the configured speed.
        let travel = strip.size.width - (800 - 2 * CrawlTickerNSView.horizontalInset)
        #expect(travel > 100, "sweep span implausibly short")
        let expected = TimeInterval(travel / 60)
        #expect(
            abs(animation.duration - expected) < 0.05,
            "loop duration \(animation.duration)s != sweep/speed \(expected)s"
        )
        // Scrub the layer timeline 0.4s: at 60pt/s right-to-left the strip
        // must sit 24pt into the sweep. No view code runs per frame — the
        // offset comes from the animation timeline, which is the whole
        // performance bet.
        let moved = view.stepLoopForTesting(seconds: 0.4)
        #expect(moved != nil, "loop did not install an animatable presentation")
        #expect(abs((moved ?? 0) - (-24)) < 1, "loop offset after 0.4s is \(String(describing: moved)), want -24")
    }

    @Test("loop reverses at the end instead of wrapping")
    @MainActor
    func loopReversesAtEnd() {
        let (view, _) = makeWindowedView()
        guard let strip = view.stripForTesting else {
            Issue.record("view rendered no strip")
            return
        }
        let travel = strip.size.width - (800 - 2 * CrawlTickerNSView.horizontalInset)
        let leg = travel / 60
        view.startLoop(fromStart: true)
        // Scrub to the very end of the first sweep: the far edge must sit
        // exactly on screen, never past the bitmap (no half-empty bar).
        let atEnd = view.stepLoopForTesting(seconds: leg)
        #expect(atEnd != nil, "loop did not install an animatable presentation")
        #expect(abs((atEnd ?? 0) - (-travel)) < 2, "sweep end at \(String(describing: atEnd)), want \(-travel)")
        // 2.5 sweeps in: past the turn and halfway back — the bounce.
        let back = view.stepLoopForTesting(seconds: 2.5 * leg)
        #expect(abs((back ?? 0) - (-travel / 2)) < 2, "after the turn at \(String(describing: back)), want \(-travel / 2)")
    }

    @Test("halt freezes the offset in place")
    @MainActor
    func haltPreservesOffset() {
        let (view, _) = makeWindowedView()
        view.startLoop(fromStart: true)
        let stepped = view.stepLoopForTesting(seconds: 0.3)
        #expect(stepped != nil && abs(stepped! - (-18)) < 1, "setup did not reach mid-flight")
        view.pauseLoop()
        #expect(!view.isLooping, "animation still live after pause")
        let frozen = view.currentOffsetForTesting
        #expect(abs(frozen - (-18)) < 1, "pause did not preserve the mid-flight offset (\(frozen))")
        // Resuming continues from the frozen spot instead of jumping.
        view.startLoop(fromStart: false)
        #expect(view.isLooping, "resume did not reinstall the loop")
        let resumed = view.loopAnimationForTesting?.values?.first as? CGFloat
        #expect(resumed == frozen, "resume restarted from \(String(describing: resumed)) instead of \(frozen)")
    }

    @Test("content refresh preserves loop progress instead of jumping")
    @MainActor
    func refreshPreservesProgress() {
        let (view, _) = makeWindowedView()
        view.startLoop(fromStart: true)
        _ = view.stepLoopForTesting(seconds: 0.3)
        var inputs = sampleInputs()
        inputs.headlines.append(CrawlHeadline(
            articleID: 3, site: "website.net", title: "Breaking news",
            url: "https://website.net/c", feedURL: "https://website.net/feed", publishedAt: 3
        ))
        view.update(with: inputs)
        #expect(view.isLooping, "refresh killed the loop")
        #expect(
            view.currentOffsetForTesting < 0,
            "refresh jumped back to the leading edge"
        )
    }

    @Test("item frames sit on whole backing pixels")
    func framesSnapToPixels() {        // Every glyph and icon origin is an integer pixel offset: fractional
        // origins rasterize straddling pixels and read as blur. Frames are in
        // points, so scaled back up they must be integral.
        guard let strip = render(sampleHeadlines()) else {
            Issue.record("no strip rendered")
            return
        }
        let scale = strip.scale
        for item in strip.items {
            let minX = item.frame.minX * scale
            let width = item.frame.width * scale
            #expect(
                abs(minX.rounded() - minX) < 0.001,
                "item starts at fractional pixel \(minX)"
            )
            #expect(
                abs(width.rounded() - width) < 0.001,
                "item spans fractional pixels \(width)"
            )
        }
        #expect(
            abs((strip.passWidth * scale).rounded() - strip.passWidth * scale) < 0.001,
            "pass width is fractional pixels"
        )
    }

    @Test("a giant strip tiles instead of dropping scale")
    func giantStripTiles() {
        // Fifty max-length titles at 16pt: far past any texture limit. The
        // old code answered this by re-rendering at 1x (permanent blur);
        // tiles keep full resolution at any font size.
        let headlines = (0..<50).map { i in
            CrawlHeadline(
                articleID: i, site: "website.com",
                title: String(repeating: "Long headline text ", count: 8),
                url: "https://website.com/\(i)", feedURL: "https://website.com/feed",
                publishedAt: i
            )
        }
        guard let tiles = CrawlStripRenderer.renderTiles(
            headlines: headlines, fontSize: 16,
            favicons: [:], scale: 2, coverWidth: 800, separator: "|"
        ) else {
            Issue.record("giant strip rendered nothing")
            return
        }
        #expect(tiles.count > 1, "giant strip came back as one tile")
        var total: CGFloat = 0
        for tile in tiles {
            #expect(tile.scale == 2, "tile dropped its backing scale")
            #expect(
                tile.bitmap.pixelsWide <= 16384,
                "tile is \(tile.bitmap.pixelsWide)px wide: past texture limits"
            )
            #expect(tile.offset == total, "tiles are not contiguous")
            total += tile.size.width
            #expect(tile.items.count == headlines.count, "tile lost the shared items")
            #expect(tile.passWidth == tiles[0].passWidth, "tiles disagree on the wrap period")
        }
        #expect(
            total >= 800 + tiles[0].passWidth - 1,
            "tiled span does not cover the bar plus a wrap pass"
        )
    }
}
