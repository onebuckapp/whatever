import Foundation
import WebKit

/// One syndication document advertised by the current page.
struct FeedCandidate: Hashable, Sendable {
    enum Format: String, Sendable {
        case rss
        case atom
        case unknown
    }

    let url: URL
    let title: String
    let type: String
    let format: Format

    init?(url: URL, title: String, type: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        self.url = url
        self.title = title
        self.type = type
        self.format = Self.format(for: type)
    }

    private static func format(for type: String) -> Format {
        switch type.lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "application/rss+xml", "application/rss", "text/rss", "application/rdf+xml":
            return .rss
        case "application/atom+xml", "application/atom":
            return .atom
        default:
            return .unknown
        }
    }
}

/// Reads standard feed-autodiscovery links from the live document.
///
/// The rendered DOM is used rather than downloading the page again, so
/// authentication, cookies, redirects, and client-rendered `<link>` elements
/// are all honoured. No feed document is fetched here; discovery only reports
/// addresses the page itself advertises.
final class FeedDiscovery {
    static let shared = FeedDiscovery()

    /// Pages already being inspected, keyed by web view. A slow script result
    /// for a page the tab has already left must not publish stale candidates.
    private var inFlight: [ObjectIdentifier: URL] = [:]

    private init() {}

    /// Calls back on the main actor with the page's advertised feeds, in
    /// document order and without duplicates.
    func candidates(
        forPageAt url: URL,
        in webView: WKWebView,
        completion: @escaping ([FeedCandidate]) -> Void
    ) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            completion([])
            return
        }
        let identity = ObjectIdentifier(webView)
        inFlight[identity] = url
        webView.evaluateJavaScript(Self.discoveryScript) { [weak self, weak webView] value, _ in
            DispatchQueue.main.async {
                guard let self, let webView, self.inFlight[identity] == url else { return }
                self.inFlight[identity] = nil
                completion(Self.candidates(from: value, pageURL: url))
            }
        }
    }

    private static func candidates(from value: Any?, pageURL: URL) -> [FeedCandidate] {
        guard let rawCandidates = value as? [[String: Any]] else {
            return []
        }
        var seen = Set<URL>()
        var candidates: [FeedCandidate] = []
        for raw in rawCandidates.prefix(8) {
            guard let href = raw["url"] as? String,
                let url = URL(string: href),
                seen.insert(url).inserted,
                let candidate = FeedCandidate(
                    url: url,
                    title: (raw["title"] as? String) ?? "",
                    type: (raw["type"] as? String) ?? ""
                )
            else {
                continue
            }
            candidates.append(candidate)
        }
        return candidates
    }

    /// Standard autodiscovery links only. Stylesheets, alternate languages,
    /// and untyped links are ignored; a candidate without a recognized
    /// syndication type would only make the toolbar promise a feed that the
    /// parser may not support. The fragment is dropped because it addresses a
    /// location inside a document rather than a different feed.
    private static let discoveryScript = """
    (() => {
      const allowed = new Set([
        'application/rss+xml',
        'application/rss',
        'text/rss',
        'application/atom+xml',
        'application/atom',
        'application/rdf+xml'
      ]);
      const found = [];
      const seen = new Set();
      for (const link of document.querySelectorAll('link[rel]')) {
        const tokens = (link.getAttribute('rel') || '').toLowerCase().split(/\\s+/);
        if (!tokens.includes('alternate')) continue;
        const type = ((link.getAttribute('type') || '').split(';')[0] || '').trim().toLowerCase();
        if (!allowed.has(type)) continue;
        const href = link.getAttribute('href');
        if (!href) continue;
        try {
          const url = new URL(href, document.baseURI);
          if (url.protocol !== 'http:' && url.protocol !== 'https:') continue;
          url.hash = '';
          if (seen.has(url.href)) continue;
          seen.add(url.href);
          found.push({
            url: url.href,
            title: link.getAttribute('title') || document.title || '',
            type: type
          });
          if (found.length >= 8) break;
        } catch (e) {}
      }
      return found;
    })()
    """
}
