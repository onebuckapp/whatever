import AppKit

/// One rendered headline inside a crawl strip: the headline plus its frame in
/// strip points. The frame covers the item's visible content (icon or site
/// name plus title) but not the trailing delimiter, so clicks on the gap
/// between items hit nothing, matching the old per-item tap targets.
struct CrawlStripItem {
    let headline: CrawlHeadline
    let frame: CGRect
}

/// A pre-rendered ticker pass: one bitmap holding the whole looping strip,
/// drawn once per content change and then scrolled as a GPU texture.
///
/// This is the crawl bar's performance story. The previous implementation kept
/// up to 600 live SwiftUI views (nested stacks, resizable clipped images, tap
/// gestures, accessibility nodes) plus a gradient mask and re-composited all
/// of it on the CPU every frame at 60fps, which pinned the app around 40%
/// CPU. Here the strip is rasterized once; the per-frame work is a single
/// layer-position interpolation done by the render server, which is ~0% CPU.
struct CrawlStrip {
    /// The full strip bitmap at `scale`, transparent background.
    let bitmap: NSBitmapImageRep
    var cgImage: CGImage? { bitmap.cgImage }
    /// Items of the first pass, in strip points. Later passes repeat
    /// identically every `passWidth`, so hit-testing takes `x mod passWidth`.
    let items: [CrawlStripItem]
    /// Width of one identical pass in points: the wrap period.
    let passWidth: CGFloat
    /// Full bitmap size in points.
    let size: CGSize
    let scale: CGFloat
}

/// Renders headline strips into cached bitmaps. Pure and synchronous: no
/// database, no network, no view hierarchy, so tests exercise it directly.
///
/// Colors resolve from the ambient appearance at draw time (`labelColor` /
/// `secondaryLabelColor`), so the caller must render under the right
/// appearance and re-render when it changes; the bitmap itself is frozen.
enum CrawlStripRenderer {
    /// Favicon box: notification-badge sized, like the old SwiftUI row.
    static let iconSize: CGFloat = 14
    /// Gap between the site marker (icon or name) and the title.
    static let siteTitleGap: CGFloat = 4
    /// Upper bound on the bitmap width in points. A full 50-headline strip of
    /// long titles can exceed this; beyond it the scale drops to 1x, and only
    /// in the unreachable extreme are trailing passes cut (coverage is still
    /// guaranteed for any real window).
    static let maxStripPoints: CGFloat = 16384

    /// Renders `headlines` into a strip covering at least `coverWidth` points
    /// (the visible width plus one pass for the wrap), repeating the item
    /// sequence as needed. Returns nil for empty headlines or degenerate
    /// metrics. All layout is single-line by construction: nothing wraps, so
    /// nothing can squeeze.
    static func render(
        headlines: [CrawlHeadline],
        fontSize: CGFloat,
        favicons: [String: NSImage],
        scale: CGFloat,
        coverWidth: CGFloat
    ) -> CrawlStrip? {
        guard !headlines.isEmpty, fontSize > 0, scale > 0 else { return nil }
        let renderScale = scale
        let font = NSFont.systemFont(ofSize: fontSize * renderScale)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]
        let secondaryAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // Measure one pass in pixels. Heights are font metrics, identical for
        // every string in the same font.
        let lineHeight = ceil((("Ag" as NSString).size(withAttributes: titleAttrs)).height)
        let iconPx = iconSize * renderScale
        let stripPxH = max(lineHeight, ceil(iconPx))
        let delimiter = CrawlContent.delimiter as NSString
        let delimiterWidth = delimiter.size(withAttributes: secondaryAttrs).width

        struct MeasuredItem {
            let headline: CrawlHeadline
            let siteWidth: CGFloat
            let titleWidth: CGFloat
            let hasIcon: Bool
            let advance: CGFloat
        }
        let gapPx = siteTitleGap * renderScale
        let items: [MeasuredItem] = headlines.map { headline in
            let icon = favicons[headline.feedURL]
            let hasIcon = icon != nil
            let siteWidth: CGFloat
            if !hasIcon, !headline.site.isEmpty {
                siteWidth = ((headline.site + ": ") as NSString).size(withAttributes: secondaryAttrs).width
            } else {
                siteWidth = 0
            }
            let titleWidth = (headline.title as NSString).size(withAttributes: titleAttrs).width
            let marker = hasIcon ? iconPx + gapPx : (siteWidth > 0 ? siteWidth + gapPx : 0)
            return MeasuredItem(
                headline: headline, siteWidth: siteWidth,
                titleWidth: titleWidth, hasIcon: hasIcon,
                advance: marker + titleWidth + delimiterWidth
            )
        }
        let passWidthPx = items.reduce(0) { $0 + $1.advance }
        guard passWidthPx > 0 else { return nil }

        // Repeat passes until the visible width plus one wrap pass is
        // covered. Fewer passes than the old copy budget: one wide bitmap,
        // not hundreds of views.
        var passes = max(1, Int(ceil((coverWidth * renderScale + passWidthPx) / passWidthPx)))
        let maxPxW = maxStripPoints * renderScale
        if CGFloat(passes) * passWidthPx > maxPxW {
            if passWidthPx > maxPxW, renderScale > 1 {
                // Giant strip (dozens of max-length titles): halve the
                // backing scale rather than allocating a 30MB texture. Only
                // affects strips far wider than any window.
                return render(
                    headlines: headlines, fontSize: fontSize,
                    favicons: favicons, scale: 1, coverWidth: coverWidth
                )
            }
            passes = max(1, Int(maxPxW / passWidthPx))
        }
        let bitmapPxW = ceil(CGFloat(passes) * passWidthPx)
        let bitmapPxH = ceil(stripPxH)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bitmapPxW), pixelsHigh: Int(bitmapPxH),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        var stripItems: [CrawlStripItem] = []
        stripItems.reserveCapacity(headlines.count)
        var cursor: CGFloat = 0
        let toPoints: CGFloat = 1 / renderScale
        for pass in 0..<passes {
            for item in items {
                let itemStart = cursor
                if item.hasIcon, let icon = favicons[item.headline.feedURL] {
                    let side = iconPx
                    icon.draw(
                        in: NSRect(x: cursor, y: (stripPxH - side) / 2, width: side, height: side),
                        from: NSRect(origin: .zero, size: icon.size),
                        operation: .sourceOver, fraction: 1.0,
                        respectFlipped: true, hints: nil
                    )
                    cursor += side + siteTitleGap * renderScale
                } else if item.siteWidth > 0 {
                    let site = ((item.headline.site + ": ") as NSString)
                    let h = site.size(withAttributes: secondaryAttrs).height
                    site.draw(at: NSPoint(x: cursor, y: (stripPxH - h) / 2), withAttributes: secondaryAttrs)
                    cursor += item.siteWidth + siteTitleGap * renderScale
                }
                let title = item.headline.title as NSString
                let titleH = title.size(withAttributes: titleAttrs).height
                title.draw(at: NSPoint(x: cursor, y: (stripPxH - titleH) / 2), withAttributes: titleAttrs)
                let contentWidth = cursor + item.titleWidth - itemStart
                if pass == 0 {
                    stripItems.append(CrawlStripItem(
                        headline: item.headline,
                        frame: CGRect(
                            x: itemStart * toPoints, y: 0,
                            width: contentWidth * toPoints,
                            height: stripPxH * toPoints
                        )
                    ))
                }
                cursor += item.titleWidth
                let delimH = delimiter.size(withAttributes: secondaryAttrs).height
                delimiter.draw(at: NSPoint(x: cursor, y: (stripPxH - delimH) / 2), withAttributes: secondaryAttrs)
                cursor += delimiterWidth
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        return CrawlStrip(
            bitmap: rep,
            items: stripItems,
            passWidth: passWidthPx * toPoints,
            size: CGSize(width: bitmapPxW * toPoints, height: stripPxH * toPoints),
            scale: renderScale
        )
    }

    /// Maps a strip-local x (points) onto the headline under it, wrapping by
    /// the pass width so any repeat resolves. Returns nil past the strip end
    /// or in the delimiter gaps.
    static func headline(at stripX: CGFloat, strip: CrawlStrip) -> CrawlHeadline? {
        guard stripX >= 0, stripX < strip.size.width else { return nil }
        let local = stripX.truncatingRemainder(dividingBy: strip.passWidth)
        for item in strip.items where local >= item.frame.minX && local < item.frame.maxX {
            return item.headline
        }
        return nil
    }
}
