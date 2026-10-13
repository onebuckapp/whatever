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

import Accelerate
import AppKit
import WebKit

/// Finds the icon a page asks for, and remembers it per site.
///
/// WebKit does not expose a page's favicon, so this asks the page for its
/// declared icons and then fetches over HTTP. When a page declares nothing,
/// the site's own `/favicon.ico` is tried, which is where a great many sites
/// keep one without ever linking to it.
///
/// Tabs draw the icon at 16pt on Retina displays, so a 16px source arrives
/// pixelated. The lookup therefore prefers a 32px source, then 48px, then the
/// smallest larger file — a 32px icon rasterizes 1:1 into the tab slot — and
/// always probes the two well-known high-res filenames, so a declared 16px
/// icon never wins while a sharper file sits one request away. Whatever wins
/// is rasterized into the tab slot (16pt, 32px of backing, lightly sharpened)
/// before it is cached or handed out, so every consumer draws the same pixels.
/// Once a Retina source is in hand the walk stops, so the probes cost nothing
/// when the declared icons already suffice.
/// source is in hand the walk stops, so the probes cost nothing when the
/// declared icons already suffice.
///
/// The icon belongs to the site rather than the page, so the cache is keyed by
/// host: moving between pages of one site does not refetch, and a site known to
/// have no icon is remembered as well so its pages are not asked twice.
///
/// Main-thread only, and not isolated as such: `BrowserTabController`, which asks
/// it for icons, is not `@MainActor` because its KVO callbacks arrive on WebKit's
/// threads. Requests start from main-thread code and every completion is hopped
/// back to the main queue.
final class FaviconLoader {
    static let shared = FaviconLoader()

    private static let maximumBytes = 512 * 1024

    /// Pixel width of the tab slot: 16pt at 2x. Sources are ranked by how
    /// close they sit above this, and the winner is rasterized down to
    /// exactly this width. Kept at 32 rather than 48: 48px of backing lands
    /// on 32 device pixels through a fractional downscale and reads
    /// pixelated again, while 32px is an exact 1:1 fit. The slight softness
    /// of a resampled 32px icon is lifted by `slotSharpness` instead.
    static let sufficientPixels = 32

    /// Luminance sharpening applied to the rasterized tab slot. 0 leaves
    /// pixels untouched; 1 is strong. 0.4 lifts the softness of a resampled
    /// 32px icon without ringing high-contrast edges. One knob for the whole
    /// feature: if tabs ever read crunchy or soft again, this is the first
    /// number to try. Scales the taps of the 3x3 kernel below.
    private static let slotSharpness: CGFloat = 0.4

    /// How many icon files one lookup tries before giving up. Declared icons
    /// plus the high-res probes; per host, once, then cached either way.
    static let maximumCandidates = 8

    private let cache = NSCache<NSString, NSImage>()
    private var hostsWithoutIcons = Set<String>()
    private var inFlight = Set<String>()
    private var sourceByHost: [String: URL] = [:]

    /// Hands back the site's icon and the address it came from, or nils when it
    /// has none and the caller should draw its default.
    ///
    /// The completion runs on the main actor, but not necessarily before this
    /// returns: a cache hit is synchronous and everything else is a fetch.
    func icon(
        forPageAt url: URL,
        in webView: WKWebView,
        completion: @escaping (NSImage?, URL?) -> Void
    ) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host
        else {
            // A homepage or an address without a site has no icon to look up.
            completion(nil, nil)
            return
        }
        if let cached = cache.object(forKey: host as NSString) {
            completion(cached, sourceByHost[host])
            return
        }
        guard !hostsWithoutIcons.contains(host), !inFlight.contains(host) else {
            completion(nil, nil)
            return
        }
        inFlight.insert(host)
        requestDeclaredIcons(in: webView, pageURL: url) { [weak self] entries in
            guard let self else { return }
            let candidates = FaviconLoader.candidates(from: entries, pageURL: url)
            self.loadLargest(candidates, host: host) { image, source in
                // Into the tab slot before caching, so the cache holds exactly
                // what every consumer draws: 16pt with 32px of backing.
                let normalized = image.map { FaviconLoader.tabIcon(from: $0) }
                if let normalized {
                    self.cache.setObject(normalized, forKey: host as NSString)
                } else {
                    self.hostsWithoutIcons.insert(host)
                }
                if let source {
                    self.sourceByHost[host] = source
                }
                self.inFlight.remove(host)
                completion(normalized, source)
            }
        }
    }

    /// Drops a site's icon, so the next page that asks refetches it.
    func forget(host: String) {
        cache.removeObject(forKey: host as NSString)
        sourceByHost.removeValue(forKey: host)
        hostsWithoutIcons.remove(host)
    }

    /// The site's icon when a previous lookup already cached it, or nil.
    ///
    /// Synchronous and network-free: history menus show what is known and
    /// fall back to their globe, rather than fetching on open. Pages the
    /// tab visited this session are warm by construction — every committed
    /// page looks its icon up — so back/forward entries usually hit.
    func cachedIcon(forPageAt url: URL) -> NSImage? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host
        else {
            return nil
        }
        return cache.object(forKey: host as NSString)
    }

    // MARK: - Private

    /// Reads `link[rel*=icon]` out of the page and reports each entry's
    /// declared size, which ranks the fetch order in `candidates`.
    ///
    /// `width` is the page's claim, 0 when undeclared; the walk measures what
    /// actually arrives, so a lying `sizes` attribute only costs order, never
    /// the outcome.
    private func requestDeclaredIcons(
        in webView: WKWebView,
        pageURL: URL,
        completion: @escaping ([(url: URL, width: Int, isTouch: Bool)]) -> Void
    ) {
        webView.evaluateJavaScript(FaviconLoader.declaredIconsScript) { value, _ in
            var resolved: [(url: URL, width: Int, isTouch: Bool)] = []
            for case let entry as [String: Any] in (value as? [[String: Any]] ?? []) {
                // Data-URI icons are kept: several large sites declare one instead
                // of hosting a file, and they need no request to arrive.
                guard let href = entry["href"] as? String,
                    let url = URL(string: href, relativeTo: pageURL)?.absoluteURL
                else { continue }
                let width = (entry["width"] as? NSNumber)?.intValue ?? 0
                let isTouch = (entry["isTouch"] as? NSNumber)?.boolValue ?? false
                resolved.append((url, width, isTouch))
            }
            completion(resolved)
        }
    }

    /// The ordered fetch list for one lookup: declared icons ranked by how
    /// well they rasterize into the 16pt tab slot, then the well-known
    /// high-res filenames, then `/favicon.ico` when the page declares nothing
    /// at all.
    ///
    /// The probes always ride along (deduped against what the page declares):
    /// when a declared icon already covers Retina the walk stops before
    /// touching them, so they cost nothing in the good case and rescue the
    /// lookup in the 16px-declared case.
    static func candidates(
        from entries: [(url: URL, width: Int, isTouch: Bool)],
        pageURL: URL
    ) -> [URL] {
        let ordered = entries.sorted { lhs, rhs in
            let left = rank(url: lhs.url, width: lhs.width, isTouch: lhs.isTouch)
            let right = rank(url: rhs.url, width: rhs.width, isTouch: rhs.isTouch)
            if left.tier != right.tier { return left.tier > right.tier }
            return left.detail > right.detail
        }.map(\.url)
        let declared = ordered.isEmpty ? [fallbackIconURL(for: pageURL)] : ordered
        let seen = Set(declared.map(\.absoluteString))
        return Array((declared + highResProbes(for: pageURL, excluding: seen)).prefix(maximumCandidates))
    }

    /// Two-level preference so one comparator covers every case. Higher wins.
    ///
    /// Tier 3 is a data URI: no request needed to try it. Tier 2 is a declared
    /// size covering the tab slot, smallest first — 32 beats 48 beats 180,
    /// because a 32px source downloads less and rasterizes 1:1 into the
    /// slot. Tier 1 is the largest small icon when nothing covers. Tier 0 is
    /// an undeclared size, touch before plain: the conventions reserve touch
    /// icons for large artwork (120px and up) while an unsized plain `icon`
    /// is usually 16 or 32px.
    private static func rank(url: URL, width: Int, isTouch: Bool) -> (tier: Int, detail: Int) {
        if url.scheme?.lowercased() == "data" { return (3, 0) }
        if width >= sufficientPixels { return (2, -width) }
        if width > 0 { return (1, width) }
        return (0, isTouch ? 1 : 0)
    }

    /// The two filenames the platform conventions reserve for large icons,
    /// resolved at the origin root where the conventions put them. Anything
    /// the page already declared is left out.
    static func highResProbes(for pageURL: URL, excluding: Set<String>) -> [URL] {
        ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"].compactMap { path in
            guard let url = URL(string: path, relativeTo: pageURL)?.absoluteURL,
                !excluding.contains(url.absoluteString)
            else { return nil }
            return url
        }
    }

    /// Tries each candidate in turn and keeps the largest icon that decodes,
    /// stopping at the first one covering Retina. First success no longer
    /// wins: a 16px declared icon must not beat a 32px file that simply sorts
    /// after it, and a page that lies in `sizes` is corrected by measurement
    /// rather than believed.
    private func loadLargest(
        _ candidates: [URL],
        host: String,
        best: (image: NSImage, source: URL)? = nil,
        completion: @escaping (NSImage?, URL?) -> Void
    ) {
        if let best, FaviconLoader.pixelWidth(of: best.image) >= FaviconLoader.sufficientPixels {
            completion(best.image, best.source)
            return
        }
        guard let next = candidates.first else {
            completion(best?.image, best?.source)
            return
        }
        let rest = Array(candidates.dropFirst())
        fetch(next) { [weak self] image in
            var nextBest = best
            if let image {
                let width = FaviconLoader.pixelWidth(of: image)
                let bestWidth = best.map { FaviconLoader.pixelWidth(of: $0.image) } ?? 0
                if width > bestWidth {
                    nextBest = (image, next)
                }
            }
            self?.loadLargest(rest, host: host, best: nextBest, completion: completion)
        }
    }

    /// The widest bitmap the image actually carries, across every
    /// representation. What AppKit decoded, not what the page declared: a
    /// multi-image `.ico` holds several sizes side by side, and only the
    /// pixels on hand decide whether the lookup can stop.
    static func pixelWidth(of image: NSImage) -> Int {
        var widest = 0
        for rep in image.representations {
            widest = max(widest, rep.pixelsWide)
        }
        if widest <= 0 {
            widest = Int(image.size.width)
        }
        return widest
    }

    /// Rasterizes an icon into the tab slot: 16pt with 32px of backing,
    /// aspect-fit on transparency, then lightly sharpened.
    ///
    /// Done up front rather than left to the image views so every consumer
    /// draws identical pixels: a tab never upscales a source itself, a 32px
    /// source lands 1:1 on Retina, and oversized sources arrive pre-shrunk
    /// instead of downsampled per frame. Returns the input untouched when
    /// rasterization fails, so a normalization bug can never lose an icon.
    static func tabIcon(from image: NSImage) -> NSImage {
        let targetPx = CGFloat(sufficientPixels)
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            source.width > 0, source.height > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int(targetPx), height: Int(targetPx),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return image }
        let scale = min(targetPx / CGFloat(source.width), targetPx / CGFloat(source.height))
        let drawn = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        context.interpolationQuality = .high
        context.draw(
            source,
            in: CGRect(
                x: (targetPx - drawn.width) / 2,
                y: (targetPx - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            )
        )
        guard let raster = context.makeImage() else { return image }
        let rep = NSBitmapImageRep(cgImage: sharpen(raster))
        rep.size = NSSize(width: 16, height: 16)
        let normalized = NSImage(size: NSSize(width: 16, height: 16))
        normalized.addRepresentation(rep)
        return normalized
    }

    /// Lifts the rasterized slot with a 3x3 sharpen convolution, run on the
    /// CPU through vImage so it behaves identically everywhere — including
    /// headless test runs with no GPU back end. The kernel sharpens all four
    /// channels together, which keeps semi-transparent edges coherent instead
    /// of fringing them. Falls back to the unsharpened raster on any failure,
    /// so filtering can soften but never lose an icon.
    static func sharpen(_ raster: CGImage) -> CGImage {
        let tap = Int16((slotSharpness * 64).rounded())
        guard tap > 0 else { return raster }
        let space = CGColorSpaceCreateDeviceRGB()
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(space),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        var src = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(
            &src, &format, nil, raster, vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError else { return raster }
        defer { free(src.data) }
        var dst = vImage_Buffer()
        guard vImageBuffer_Init(
            &dst, src.height, src.width, format.bitsPerPixel, vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError else { return raster }
        // Center 1 + 4 taps, edges −1 tap, over a 256 divisor: a conventional
        // mild sharpen. Edges extend rather than wrap or blacken, so the
        // slot's own border never darkens.
        let kernel: [Int16] = [0, -tap, 0, -tap, 256 + 4 * tap, -tap, 0, -tap, 0]
        let error = kernel.withUnsafeBufferPointer { pointer in
            vImageConvolve_ARGB8888(
                &src, &dst, nil, 0, 0, pointer.baseAddress, 3, 3, 256, nil,
                vImage_Flags(kvImageEdgeExtend)
            )
        }
        guard error == kvImageNoError else { free(dst.data); return raster }
        // The destination bytes move into the image: freed when it dies.
        let bytes = Data(
            bytesNoCopy: dst.data,
            count: Int(dst.height) * Int(dst.rowBytes),
            deallocator: .free
        )
        guard let provider = CGDataProvider(data: bytes as CFData),
            let out = CGImage(
                width: Int(dst.width),
                height: Int(dst.height),
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: Int(dst.rowBytes),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else { return raster }
        return out
    }

    private func fetch(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        // An icon delivered as a data URI needs no request at all.
        if url.scheme?.lowercased() == "data", let image = FaviconLoader.image(from: url) {
            completion(image)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Some sites serve a placeholder to requests that admit to being a
        // browser. Not worth impersonating one for an icon.
        request.setValue("image/avif,image/webp,image/png,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let image: NSImage? = {
                guard let response = response as? HTTPURLResponse,
                    (200..<300).contains(response.statusCode),
                    let data,
                    !data.isEmpty,
                    data.count <= FaviconLoader.maximumBytes
                else { return nil }
                return NSImage(data: data)
            }()
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    private static func image(from dataURL: URL) -> NSImage? {
        guard dataURL.scheme?.lowercased() == "data",
            let comma = dataURL.absoluteString.firstIndex(of: ",")
        else { return nil }
        let absolute = dataURL.absoluteString
        let meta = String(absolute[absolute.startIndex..<comma]).lowercased()
        let payload = String(absolute[absolute.index(after: comma)...])
        let bytes: Data?
        if meta.hasSuffix(";base64") {
            bytes = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            bytes = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let bytes, !bytes.isEmpty, bytes.count <= maximumBytes else { return nil }
        return NSImage(data: bytes)
    }

    private static func fallbackIconURL(for pageURL: URL) -> URL {
        URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL ?? pageURL
    }

    /// Reads the declared icons and reports each one's declared size, which is the
    /// only way to tell a Retina icon from a 1x one without downloading both.
    private static let declaredIconsScript = """
    (() => {
      const found = [];
      for (const link of document.querySelectorAll('link[rel]')) {
        const rel = (link.getAttribute('rel') || '').toLowerCase();
        if (rel.indexOf('icon') === -1) continue;
        const href = link.getAttribute('href');
        if (!href) continue;
        const sizes = link.getAttribute('sizes') || '';
        const match = sizes.match(/(\\d+)\\s*[xX]\\s*(\\d+)/);
        let width = 0;
        if (match) width = Math.max(parseInt(match[1], 10), parseInt(match[2], 10));
        found.push({
          href: href,
          width: width,
          isTouch: rel.indexOf('apple-touch') !== -1
        });
      }
      return found;
    })()
    """
}