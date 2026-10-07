import Foundation

/// Shared constants for the Whatever browser.
enum BrowserConstants {
    /// Homepage markup served from memory for `w://about` by
    /// `HomepageSchemeHandler`. Read from the bundle once at startup.
    static let homePageHTML: String = {
        guard let url = Bundle.main.url(forResource: "home", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8),
              !html.isEmpty
        else {
            return "<html><body></body></html>"
        }
        return html
    }()

    /// Address of the homepage. It is a real navigation (served by the
    /// scheme handler), so reload and back/forward work on it — but it has
    /// no user-facing address; see `URL.isAddresslessPage`.
    static let homePageURL = URL(string: "w://about")!

}

extension URL {
    /// `true` for pages with no user-facing address: `about:blank` backing
    /// string-loaded content, and the `w://` homepage (`whtvr://` stays
    /// addressless too, so stored URLs from before the rename keep working).
    var isAddresslessPage: Bool {
        absoluteString == "about:blank" || ["w", "whtvr"].contains(scheme?.lowercased() ?? "")
    }

    /// Whether two addresses name the same page for history purposes: same
    /// scheme, host, port, path, query, and fragment.
    ///
    /// A bare-host path compares equal to `/`: WebKit reports a committed
    /// bare host with the trailing slash the address bar never typed, and
    /// without this the reconcile in `BrowserTab.noteCommitted(url:)` would log
    /// a duplicate entry for every such navigation.
    func hasSameAddress(as other: URL) -> Bool {
        func normalizedPath(_ url: URL) -> String {
            // Trailing slashes carry no address meaning here: WebKit reports a
            // committed bare host with one the address bar never typed, and
            // servers treat a trailing slash as the same resource.
            var path = url.path
            while path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        }
        return scheme?.lowercased() == other.scheme?.lowercased()
            && host?.lowercased() == other.host?.lowercased()
            && port == other.port
            && normalizedPath(self) == normalizedPath(other)
            && query == other.query
            && fragment == other.fragment
    }
}
