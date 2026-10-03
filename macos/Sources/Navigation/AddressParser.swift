import Foundation

/// Turns address-field input into a URL.
///
/// - Text with a scheme (`https://…`) loads as-is.
/// - Scheme-less text containing a dot (`example.com`) becomes `https://…`.
/// - Anything else is sent to the search engine.
enum AddressParser {
    static func url(
        from input: String,
        searchBaseURL: URL = BrowserConstants.searchBaseURL
    ) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), url.scheme != nil {
            return url
        }

        if !text.contains(" "), let url = URL(string: "https://\(text)"), text.contains(".") {
            return url
        }

        var components = URLComponents(url: searchBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: BrowserConstants.searchQueryItemName, value: text)]
        return components?.url
    }
}
