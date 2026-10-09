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
    /// This tile's left edge in strip points: 0 for a whole strip, the
    /// prefix width before it for a tile.
    let offset: CGFloat
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
    /// Upper bound on one tile's width in points. A strip wider than this is
    /// cut into tiles rather than shrunk: shrinking would drop the backing
    /// scale and read as blur, while tiles keep full resolution at any font
    /// size. Sized so a tile never exceeds common GPU texture limits
    /// (8192pt at 2x is 16384px).
    static let maxTilePoints: CGFloat = 8192

    /// Renders `headlines` into a strip covering at least `coverWidth` points
    /// (the visible width plus one pass for the wrap), repeating the item
    /// sequence as needed. Returns nil for empty headlines or degenerate
    /// metrics. All layout is single-line by construction: nothing wraps, so
    /// nothing can squeeze.
    ///
    /// Small strips come back as one tile; anything wider than
    /// `maxTilePoints` is cut into tiles that share the same items,
    /// pass width, and scale, so a 16pt strip stays at full resolution
    /// instead of dropping a scale.
    static func render(
        headlines: [CrawlHeadline],
        fontSize: CGFloat,
        favicons: [String: NSImage],
        scale: CGFloat,
        coverWidth: CGFloat,
        separator: String = CrawlContent.defaultSeparator
    ) -> CrawlStrip? {
        renderTiles(
            headlines: headlines, fontSize: fontSize,
            favicons: favicons, scale: scale, coverWidth: coverWidth,
            separator: separator
        )?.first
    }

    /// The tiled render behind `render`: one bitmap per tile, each no wider
    /// than `maxTilePoints`, all sharing the first pass's items.
    static func renderTiles(
        headlines: [CrawlHeadline],
        fontSize: CGFloat,
        favicons: [String: NSImage],
        scale: CGFloat,
        coverWidth: CGFloat,
        separator: String = CrawlContent.defaultSeparator
    ) -> [CrawlStrip]? {
        guard let measured = measure(
            headlines: headlines, fontSize: fontSize,
            favicons: favicons, scale: scale, separator: separator
        ) else { return nil }
        // Repeat passes until the visible width plus one wrap pass is
        // covered.
        let passes = max(1, Int(ceil(
            (coverWidth * measured.scale + measured.passWidthPx) / measured.passWidthPx
        )))
        let totalPx = CGFloat(passes) * measured.passWidthPx
        let tileCapPx = maxTilePoints * measured.scale
        var tiles: [CrawlStrip] = []
        var x: CGFloat = 0
        while x < totalPx {
            let widthPx = min(tileCapPx, totalPx - x)
            guard let rep = drawTile(
                measured, favicons: favicons,
                passes: passes, xRangePx: x..<(x + widthPx)
            ) else { return nil }
            tiles.append(CrawlStrip(
                bitmap: rep,
                items: measured.passItems,
                passWidth: measured.passWidthPx * measured.toPoints,
                size: CGSize(
                    width: widthPx * measured.toPoints,
                    height: ceil(measured.stripPxH) * measured.toPoints
                ),
                scale: measured.scale,
                offset: x * measured.toPoints
            ))
            x += widthPx
        }
        return tiles.isEmpty ? nil : tiles
    }

    /// One measured headline: pixel widths plus its stride.
    private struct MeasuredItem {
        let headline: CrawlHeadline
        let siteWidth: CGFloat
        let titleWidth: CGFloat
        let hasIcon: Bool
        let advance: CGFloat
    }

    /// Everything a tile draw needs, measured once for the whole strip.
    private struct MeasuredStrip {
        let items: [MeasuredItem]
        /// First pass's items in points, shared by every tile: hit-testing
        /// wraps by the pass width, so tiles carry no items of their own.
        let passItems: [CrawlStripItem]
        let passWidthPx: CGFloat
        let stripPxH: CGFloat
        let scale: CGFloat
        let toPoints: CGFloat
        let titleAttrs: [NSAttributedString.Key: Any]
        let secondaryAttrs: [NSAttributedString.Key: Any]
        let delimiter: NSString
        let delimiterWidth: CGFloat
        let gapPx: CGFloat
        let iconPx: CGFloat
    }

    private static func measure(
        headlines: [CrawlHeadline],
        fontSize: CGFloat,
        favicons: [String: NSImage],
        scale: CGFloat,
        separator: String
    ) -> MeasuredStrip? {
        guard !headlines.isEmpty, fontSize > 0, scale > 0 else { return nil }
        let renderScale = scale
        let toPoints: CGFloat = 1 / renderScale
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
        let delimiter = CrawlContent.delimiter(separator: separator) as NSString
        // Ceiled: advances stay on whole pixels (see below), and the same
        // value drives both measurement and drawing.
        let delimiterWidth = ceil(delimiter.size(withAttributes: secondaryAttrs).width)

        let gapPx = siteTitleGap * renderScale
        // Every width ceiled to whole pixels. The draw loop advances its
        // cursor by these same values, so every glyph and icon origin lands
        // on a pixel boundary; fractional origins rasterize straddling
        // pixels and read as blur. Costs at most a pixel of air per item.
        let items: [MeasuredItem] = headlines.map { headline in
            let icon = favicons[headline.feedURL]
            let hasIcon = icon != nil
            let siteWidth: CGFloat
            if !hasIcon, !headline.site.isEmpty {
                siteWidth = ceil(((headline.site + ": ") as NSString).size(withAttributes: secondaryAttrs).width)
            } else {
                siteWidth = 0
            }
            let titleWidth = ceil((headline.title as NSString).size(withAttributes: titleAttrs).width)
            let marker = hasIcon ? iconPx + gapPx : (siteWidth > 0 ? siteWidth + gapPx : 0)
            return MeasuredItem(
                headline: headline, siteWidth: siteWidth,
                titleWidth: titleWidth, hasIcon: hasIcon,
                advance: marker + titleWidth + delimiterWidth
            )
        }
        let passWidthPx = items.reduce(0) { $0 + $1.advance }
        guard passWidthPx > 0 else { return nil }

        // First pass's frames in points, from the same advances the draw
        // loop walks, so measurement and ink never disagree.
        var cursor: CGFloat = 0
        var passItems: [CrawlStripItem] = []
        passItems.reserveCapacity(headlines.count)
        for item in items {
            let itemStart = cursor
            let marker = item.hasIcon
                ? iconPx + gapPx
                : (item.siteWidth > 0 ? item.siteWidth + gapPx : 0)
            cursor += marker
            let contentWidth = cursor + item.titleWidth - itemStart
            passItems.append(CrawlStripItem(
                headline: item.headline,
                frame: CGRect(
                    x: itemStart * toPoints, y: 0,
                    width: contentWidth * toPoints,
                    height: stripPxH * toPoints
                )
            ))
            cursor += item.titleWidth + delimiterWidth
        }

        return MeasuredStrip(
            items: items, passItems: passItems,
            passWidthPx: passWidthPx, stripPxH: stripPxH,
            scale: renderScale, toPoints: toPoints,
            titleAttrs: titleAttrs, secondaryAttrs: secondaryAttrs,
            delimiter: delimiter, delimiterWidth: delimiterWidth,
            gapPx: gapPx, iconPx: iconPx
        )
    }

    /// Draws one tile: the pixel range `xRangePx` of the `passes`-pass strip.
    /// The context is translated so drawing uses global strip coordinates
    /// and clips to the tile; items fully outside are skipped, never
    /// partially drawn, so seams carry no double ink.
    private static func drawTile(
        _ measured: MeasuredStrip,
        favicons: [String: NSImage],
        passes: Int,
        xRangePx: Range<CGFloat>
    ) -> NSBitmapImageRep? {
        let widthPx = ceil(xRangePx.upperBound - xRangePx.lowerBound)
        let heightPx = ceil(measured.stripPxH)
        guard widthPx > 0, heightPx > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(widthPx), pixelsHigh: Int(heightPx),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // Offscreen contexts do not inherit the window's font smoothing: text
        // would rasterize with hard 1-bit edges. Grayscale antialiasing is
        // the best an offscreen bitmap gets (there is no LCD geometry for
        // subpixel smoothing), and it is what makes the strip read as text
        // rather than pixels.
        context.cgContext.setShouldAntialias(true)
        context.cgContext.setAllowsAntialiasing(true)
        context.cgContext.setShouldSmoothFonts(true)
        context.cgContext.setAllowsFontSmoothing(true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: -xRangePx.lowerBound, y: 0)

        var cursor: CGFloat = 0
        // Vertical origins snapped like the horizontal ones: an odd strip
        // height would otherwise centre every row on a half pixel.
        let centeredY: (CGFloat) -> CGFloat = { h in round((measured.stripPxH - h) / 2) }
        for _ in 0..<passes {
            for item in measured.items {
                let itemStart = cursor
                let itemEnd = itemStart + item.advance
                defer { cursor = itemEnd }
                guard itemEnd > xRangePx.lowerBound, itemStart < xRangePx.upperBound else { continue }
                if item.hasIcon, let icon = favicons[item.headline.feedURL] {
                    let side = measured.iconPx
                    icon.draw(
                        in: NSRect(x: cursor, y: centeredY(side), width: side, height: side),
                        from: NSRect(origin: .zero, size: icon.size),
                        operation: .sourceOver, fraction: 1.0,
                        respectFlipped: true, hints: nil
                    )
                    cursor += side + measured.gapPx
                } else if item.siteWidth > 0 {
                    let site = ((item.headline.site + ": ") as NSString)
                    let h = site.size(withAttributes: measured.secondaryAttrs).height
                    site.draw(at: NSPoint(x: cursor, y: centeredY(h)), withAttributes: measured.secondaryAttrs)
                    cursor += item.siteWidth + measured.gapPx
                }
                let title = item.headline.title as NSString
                let titleH = title.size(withAttributes: measured.titleAttrs).height
                title.draw(at: NSPoint(x: cursor, y: centeredY(titleH)), withAttributes: measured.titleAttrs)
                cursor += item.titleWidth
                let delimH = measured.delimiter.size(withAttributes: measured.secondaryAttrs).height
                measured.delimiter.draw(at: NSPoint(x: cursor, y: centeredY(delimH)), withAttributes: measured.secondaryAttrs)
                cursor += measured.delimiterWidth
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep
    }

    /// Maps a strip-local x (points) onto the headline under it, wrapping by
    /// the pass width so any repeat resolves. Returns nil past the strip end
    /// or in the delimiter gaps.
    static func headline(at stripX: CGFloat, strip: CrawlStrip) -> CrawlHeadline? {
        headline(
            at: stripX, items: strip.items,
            passWidth: strip.passWidth, spanWidth: strip.size.width
        )
    }

    /// The tiled lookup: items and the wrap period are shared across tiles,
    /// but the span is the whole tiled width, not one tile's. Looking up
    /// past the first tile against that tile's own width would reject every
    /// click it contains.
    static func headline(
        at stripX: CGFloat,
        items: [CrawlStripItem],
        passWidth: CGFloat,
        spanWidth: CGFloat
    ) -> CrawlHeadline? {
        guard stripX >= 0, stripX < spanWidth, passWidth > 0 else { return nil }
        let local = stripX.truncatingRemainder(dividingBy: passWidth)
        for item in items where local >= item.frame.minX && local < item.frame.maxX {
            return item.headline
        }
        return nil
    }
}
