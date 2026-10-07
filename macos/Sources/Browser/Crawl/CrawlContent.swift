import Foundation

/// One headline as the crawl bar shows it.
///
/// Deliberately decoupled from `FeedArticleSummary`: the store maps feed rows
/// onto this shape, and everything here stays pure and unit-testable without a
/// database, XPC, or network.
struct CrawlHeadline: Hashable, Sendable, Identifiable {
    var id: Int64 { articleID }
    let articleID: Int64
    let site: String
    let title: String
    let url: String
    /// Owning subscription, for favicon lookup. Empty when unknown.
    let feedURL: String
    let publishedAt: Int64
}

/// Pure headline formatting for the crawl bar.
///
/// The ticker renders `site: title` items separated by a visible delimiter:
/// `website.com: Lorem ipsum   |   website.org: Something is happening`.
enum CrawlContent {
    /// Visible separator between items in the joined ticker string.
    static let delimiter = "   |   "
    /// Maximum headlines carried in one ticker pass.
    static let maxItems = 50
    /// Titles longer than this are cut with an ellipsis so one verbose feed
    /// cannot dominate the loop.
    static let maxTitleLength = 140

    /// Builds ticker-ready headlines from feed rows: newest first, empties
    /// dropped, duplicates collapsed to their newest occurrence.
    static func headlines(
        from articles: [FeedArticleSummary],
        maxItems: Int = maxItems
    ) -> [CrawlHeadline] {
        var seen = Set<String>()
        var out: [CrawlHeadline] = []
        out.reserveCapacity(min(articles.count, maxItems))
        for article in articles.sorted(by: { $0.publishedAt > $1.publishedAt }) {
            guard out.count < maxItems else { break }
            let site = cleanFragment(article.displaySite)
            var title = cleanFragment(article.displayTitle)
            guard !title.isEmpty else { continue }
            title = truncate(title, limit: maxTitleLength)
            // Duplicates compare case-insensitively on the cleaned title, so
            // "Foo" re-published by an aggregator does not appear twice.
            guard seen.insert(title.lowercased()).inserted else { continue }
            out.append(CrawlHeadline(
                articleID: article.articleID,
                site: site,
                title: title,
                url: article.url,
                feedURL: article.feedURL,
                publishedAt: article.publishedAt
            ))
        }
        return out
    }

    /// Renders one item as `site: title`, or bare `title` when the feed
    /// carries no site name (so the bar never shows a leading `": "`).
    static func itemText(site: String, title: String) -> String {
        site.isEmpty ? title : "\(site): \(title)"
    }

    /// Joins headlines into the single scrolling string. Empty input yields
    /// `""`, which is the store's signal to hide the bar.
    static func tickerText(for headlines: [CrawlHeadline]) -> String {
        headlines.map { itemText(site: $0.site, title: $0.title) }.joined(separator: delimiter)
    }

    /// Collapses all whitespace and control characters (newlines, tabs,
    /// feed-embedded `\r\n`) to single spaces and trims the ends, so one
    /// malformed title cannot break the single-line layout. Zero-width
    /// format characters are content, not controls, and pass through.
    static func cleanFragment(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Cuts overlong text at a grapheme-cluster boundary and appends an
    /// ellipsis. Short text passes through untouched.
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
