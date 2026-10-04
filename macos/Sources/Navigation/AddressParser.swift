import Foundation

/// Turns address-field input into a URL.
///
/// - Text with a scheme (`https://…`) loads as-is.
/// - Scheme-less text containing a dot (`example.com`) becomes `https://…`.
/// - Anything else is sent to the search engine the user chose.
enum AddressParser {
    /// The engine is a parameter rather than a constant because the user can pick
    /// it, or add their own, in Settings.
    static func url(from input: String, searchEngine: ResolvedSearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), url.scheme != nil {
            return url
        }

        if !text.contains(" "), let url = URL(string: "https://\(text)"), text.contains(".") {
            return url
        }

        return searchEngine.searchURL(for: text)
    }
}