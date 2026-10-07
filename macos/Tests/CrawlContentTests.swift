import Foundation
import Testing
@testable import Whatever

/// Headline formatting behind the crawl bar: `site: title` items joined with
/// the ticker delimiter.
struct CrawlContentTests {
    private func articles(_ rows: [[String: Any]]) -> [FeedArticleSummary] {
        let data = try! JSONSerialization.data(withJSONObject: rows)
        return FeedArticleSummary.decodeList(data)
    }

    private func row(
        id: Int64,
        title: String,
        site: String = "website.com",
        publishedAt: Int64 = 1_700_000_000,
        url: String = "https://website.com/a"
    ) -> [String: Any] {
        [
            "id": id,
            "feedURL": "https://website.com/feed",
            "guid": "g\(id)",
            "url": url,
            "title": title,
            "publishedAt": publishedAt,
            "siteName": site,
        ]
    }

    @Test("item renders as site, colon, headline")
    func itemFormat() {
        #expect(CrawlContent.itemText(site: "website.com", title: "Lorem ipsum") == "website.com: Lorem ipsum")
    }

    @Test("item without a site renders the bare headline")
    func itemWithoutSite() {
        #expect(CrawlContent.itemText(site: "", title: "Lorem ipsum") == "Lorem ipsum")
    }

    @Test("items join with the visible delimiter")
    func delimiterJoin() {
        let headlines = CrawlContent.headlines(from: articles([
            row(id: 1, title: "Lorem ipsum dolor sit amet", publishedAt: 2),
            row(id: 2, title: "Something is happening", site: "website.org", publishedAt: 1),
        ]))
        #expect(CrawlContent.tickerText(for: headlines)
            == "website.com: Lorem ipsum dolor sit amet   |   website.org: Something is happening")
    }

    @Test("empty feed list yields no text, the bar's hide signal")
    func emptyFeed() {
        #expect(CrawlContent.headlines(from: []).isEmpty)
        #expect(CrawlContent.tickerText(for: []) == "")
    }

    @Test("headlines order newest first")
    func newestFirst() {
        let headlines = CrawlContent.headlines(from: articles([
            row(id: 1, title: "Old", publishedAt: 100),
            row(id: 2, title: "New", publishedAt: 300),
            row(id: 3, title: "Middle", publishedAt: 200),
        ]))
        #expect(headlines.map(\.title) == ["New", "Middle", "Old"])
    }

    @Test("duplicate headlines collapse to the newest, case-insensitively")
    func duplicates() {
        let headlines = CrawlContent.headlines(from: articles([
            row(id: 1, title: "Same story", publishedAt: 100),
            row(id: 2, title: "SAME STORY", publishedAt: 300),
        ]))
        #expect(headlines.count == 1)
        #expect(headlines.first?.articleID == 2)
    }

    @Test("newlines, tabs, and extra spaces collapse to single spaces")
    func whitespace() {
        let headlines = CrawlContent.headlines(from: articles([
            row(id: 1, title: "Line one\r\n\t  line two"),
        ]))
        #expect(headlines.first?.title == "Line one line two")
    }

    @Test("very long headlines truncate with an ellipsis")
    func truncation() {
        let long = String(repeating: "word ", count: 60)
        let headlines = CrawlContent.headlines(from: articles([row(id: 1, title: long)]))
        let title = headlines.first?.title ?? ""
        #expect(title.hasSuffix("…"))
        #expect(title.count <= CrawlContent.maxTitleLength + 1)
    }

    @Test("unusual characters pass through untouched")
    func unusualCharacters() {
        let headlines = CrawlContent.headlines(from: articles([
            row(id: 1, title: "日本語ニュース 🚀 “quoted” & <tags> — café"),
        ]))
        #expect(headlines.first?.title == "日本語ニュース 🚀 “quoted” & <tags> — café")
    }

    @Test("articles with neither title nor URL are dropped")
    func emptyArticles() {
        let headlines = CrawlContent.headlines(from: articles([
            row(id: 1, title: "", url: ""),
        ]))
        #expect(headlines.isEmpty)
    }

    @Test("headline count is capped")
    func maxItems() {
        let rows = (1...120).map { row(id: Int64($0), title: "Story \($0)", publishedAt: Int64($0)) }
        #expect(CrawlContent.headlines(from: articles(rows)).count == CrawlContent.maxItems)
    }

    @Test("scroll direction round-trips through settings storage")
    func directionSettings() {
        #expect(AppSettings.CrawlDirection.rightToLeft.title == "Right to left")
        #expect(AppSettings.CrawlDirection.leftToRight.title == "Left to right")
        let encoded = try! JSONEncoder().encode(AppSettings.CrawlDirection.leftToRight)
        #expect(try! JSONDecoder().decode(AppSettings.CrawlDirection.self, from: encoded) == .leftToRight)
    }

    @Test("headlines carry the owning feed URL for favicon lookup")
    func feedURLMapping() {
        let headlines = CrawlContent.headlines(from: articles([
            row(id: 1, title: "Hello"),
        ]))
        #expect(headlines.first?.feedURL == "https://website.com/feed")
    }

    @Test("crawl settings default to a hidden, right-to-left bar")
    func crawlDefaults() {
        let feeds = AppSettings.FeedSettings()
        #expect(feeds.crawlEnabled == false)
        #expect(feeds.crawlSpeed == 60)
        #expect(feeds.crawlDirection == .rightToLeft)
        #expect(feeds.crawlFontSize == 12)
        #expect(feeds.crawlBarHeight == 28)
        #expect(feeds.crawlBackgroundOpacity == 0.85)
    }
}
