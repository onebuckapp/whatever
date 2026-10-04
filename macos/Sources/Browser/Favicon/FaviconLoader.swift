import AppKit
import WebKit

/// Finds the icon a page asks for, and remembers it per site.
///
/// WebKit does not expose a page's favicon, so this asks the page for its
/// declared icons and then fetches one over HTTP. When a page declares nothing,
/// the site's own `/favicon.ico` is tried, which is where a great many sites
/// keep one without ever linking to it.
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

    private let cache = NSCache<NSString, NSImage>()
    private var hostsWithoutIcons = Set<String>()
    private var inFlight = Set<String>()

    /// Hands back the site's icon, or `nil` when it has none and the caller
    /// should draw its default.
    ///
    /// The completion runs on the main actor, but not necessarily before this
    /// returns: a cache hit is synchronous and everything else is a fetch.
    func icon(forPageAt url: URL, in webView: WKWebView, completion: @escaping (NSImage?) -> Void) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host
        else {
            // A homepage or an address without a site has no icon to look up.
            completion(nil)
            return
        }
        if let cached = cache.object(forKey: host as NSString) {
            completion(cached)
            return
        }
        guard !hostsWithoutIcons.contains(host), !inFlight.contains(host) else {
            completion(nil)
            return
        }
        inFlight.insert(host)
        requestDeclaredIcons(in: webView, pageURL: url) { [weak self] icons in
            guard let self else { return }
            let candidates = icons.isEmpty ? [FaviconLoader.fallbackIconURL(for: url)] : icons
            self.loadFirst(candidates, host: host) { image in
                if let image {
                    self.cache.setObject(image, forKey: host as NSString)
                } else {
                    self.hostsWithoutIcons.insert(host)
                }
                self.inFlight.remove(host)
                completion(image)
            }
        }
    }

    /// Drops a site's icon, so the next page that asks refetches it.
    func forget(host: String) {
        cache.removeObject(forKey: host as NSString)
        hostsWithoutIcons.remove(host)
    }

    // MARK: - Private

    /// Reads `link[rel*=icon]` out of the page and orders the candidates so the
    /// largest one wins, since the biggest declared icon is the one that stays
    /// sharp at 16pt on a Retina display. A touch icon is only preferred when it
    /// is actually bigger, because it is usually a padded, heavier design.
    private func requestDeclaredIcons(
        in webView: WKWebView,
        pageURL: URL,
        completion: @escaping ([URL]) -> Void
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
            resolved.sort { lhs, rhs in
                if lhs.width != rhs.width { return lhs.width > rhs.width }
                return !lhs.isTouch && rhs.isTouch
            }
            completion(resolved.map(\.url))
        }
    }

    /// Tries each candidate in turn and keeps the first that decodes to an image.
    private func loadFirst(
        _ candidates: [URL],
        host: String,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard let next = candidates.first else {
            completion(nil)
            return
        }
        let rest = Array(candidates.dropFirst())
        fetch(next) { [weak self] image in
            if let image {
                completion(image)
            } else {
                self?.loadFirst(rest, host: host, completion: completion)
            }
        }
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