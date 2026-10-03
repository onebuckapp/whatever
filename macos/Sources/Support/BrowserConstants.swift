import Foundation

/// Shared constants for the Whatever browser.
enum BrowserConstants {
    /// Homepage markup served from memory for `whtvr://about` by
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
    static let homePageURL = URL(string: "whtvr://about")!

    /// Search engine used when the address field input is not a URL.
    /// DuckDuckGo takes the query in the `q` query item.
    static let searchBaseURL = URL(string: "https://duckduckgo.com/")!
    static let searchQueryItemName = "q"
}

extension URL {
    /// `true` for pages with no user-facing address: `about:blank` backing
    /// string-loaded content, and the `whtvr://` homepage.
    var isAddresslessPage: Bool {
        absoluteString == "about:blank" || scheme?.lowercased() == "whtvr"
    }
}
