import Foundation

/// Turns address-field input into a URL.
///
/// - Text with a scheme (`https://…`, `file:///…`) loads as-is.
/// - Absolute filesystem paths (`/tmp/foo`) and home-relative ones (`~/docs`)
///   become `file://` URLs.
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

        // Absolute paths never reach the search engine: `/tmp/foo` means the
        // folder, not a search for the words. `~` expands the same way the
        // shell does, so `~/docs` needs no translation either.
        if text.hasPrefix("/") {
            return URL(fileURLWithPath: text)
        }
        if text == "~" || text.hasPrefix("~/") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }

        if !text.contains(" "), let url = URL(string: "https://\(text)"), text.contains(".") {
            return url
        }

        return searchEngine.searchURL(for: text)
    }
}