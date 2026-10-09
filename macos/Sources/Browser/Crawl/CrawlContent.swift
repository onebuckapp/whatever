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
    /// Fallback mark when the stored separator is empty or whitespace-only.
    static let defaultSeparator = "|"
    /// Maximum separator length in user-perceived characters, so `•`, `››`,
    /// and emoji alike fit the 1–2 mark the settings input promises.
    static let maxSeparatorLength = 2
    /// Visible separator between items in the joined ticker string.
    static let delimiter = delimiter(separator: defaultSeparator)
    /// Maximum headlines carried in one ticker pass.
    static let maxItems = 50
    /// Titles longer than this are cut with an ellipsis so one verbose feed
    /// cannot dominate the loop.
    static let maxTitleLength = 140

    /// Normalizes a stored separator: the first two grapheme clusters, or
    /// the default mark when nothing visible remains. Grapheme-based so a
    /// composed `é` or an emoji counts as one character, not several scalars.
    static func normalizedSeparator(_ raw: String) -> String {
        let mark = String(raw.prefix(maxSeparatorLength))
        return mark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultSeparator : mark
    }

    /// Builds the padded item delimiter (`"   |   "`) around the mark, so a
    /// custom separator keeps the same breathing room as the default.
    static func delimiter(separator: String) -> String {
        "   \(normalizedSeparator(separator))   "
    }

    /// Builds ticker-ready headlines from feed rows.
    ///
    /// Newest first within each feed, duplicates collapsed to their newest
    /// occurrence, then feeds interleaved round-robin so one prolific source
    /// cannot crowd the rest past `maxItems`. Several feeds scramble into a
    /// fresh random order on every build; a lone feed keeps chronological
    /// order, which is the only order it has.
    static func headlines(
        from articles: [FeedArticleSummary],
        maxItems: Int = maxItems
    ) -> [CrawlHeadline] {
        var seen = Set<String>()
        var ranked: [CrawlHeadline] = []
        ranked.reserveCapacity(min(articles.count, maxItems))
        for article in articles.sorted(by: { $0.publishedAt > $1.publishedAt }) {
            let site = cleanFragment(article.displaySite)
            var title = cleanFragment(article.displayTitle)
            guard !title.isEmpty else { continue }
            title = truncate(title, limit: maxTitleLength)
            // Duplicates compare case-insensitively on the cleaned title, so
            // "Foo" re-published by an aggregator does not appear twice.
            guard seen.insert(title.lowercased()).inserted else { continue }
            ranked.append(CrawlHeadline(
                articleID: article.articleID,
                site: site,
                title: title,
                url: article.url,
                feedURL: article.feedURL,
                publishedAt: article.publishedAt
            ))
        }
        // Group by owning feed in first-seen (newest-item) order.
        var groups: [[CrawlHeadline]] = []
        var indexByFeed: [String: Int] = [:]
        for headline in ranked {
            if let index = indexByFeed[headline.feedURL] {
                groups[index].append(headline)
            } else {
                indexByFeed[headline.feedURL] = groups.count
                groups.append([headline])
            }
        }
        // Round-robin across feeds up to the cap: every subscription stays
        // represented no matter how uneven the publishing rates are.
        var out: [CrawlHeadline] = []
        out.reserveCapacity(min(ranked.count, maxItems))
        var round = 0
        var progressed = true
        while out.count < maxItems, progressed {
            progressed = false
            for group in groups where round < group.count {
                out.append(group[round])
                progressed = true
                if out.count >= maxItems { break }
            }
            round += 1
        }
        return groups.count > 1 ? out.shuffled() : out
    }

    /// Renders one item as `site: title`, or bare `title` when the feed
    /// carries no site name (so the bar never shows a leading `": "`).
    static func itemText(site: String, title: String) -> String {
        site.isEmpty ? title : "\(site): \(title)"
    }

    /// Joins headlines into the single scrolling string. Empty input yields
    /// `""`, which is the store's signal to hide the bar.
    static func tickerText(
        for headlines: [CrawlHeadline],
        separator: String = defaultSeparator
    ) -> String {
        headlines.map { itemText(site: $0.site, title: $0.title) }
            .joined(separator: delimiter(separator: separator))
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
