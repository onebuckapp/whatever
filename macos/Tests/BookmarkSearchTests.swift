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
import Testing
@testable import Whatever

/// Bookmarks in the address bar: in-process matching over the prewarmed
/// cache, bridged to history entries, blended under one ordering.
struct BookmarkSearchTests {
    private func link(
        id: String = UUID().uuidString,
        title: String,
        url: String
    ) -> BookmarkNode {
        BookmarkNode(id: id, kind: .link, title: title, url: url)
    }

    private func historyEntry(url: String, title: String, visits: Int, score: Double) -> HistoryFuzzyEntry {
        let json = """
        [{"id":"h-\(url.hashValue)","url":"\(url)","title":"\(title)","host":"example.com",\
        "firstVisited":1700000000,"lastVisited":1700000100,"visitCount":\(visits),\
        "score":\(score),"titlePositions":[],"urlPositions":[]}]
        """
        let entries = HistoryFuzzyEntry.decodeList(json.data(using: .utf8)!)
        #expect(entries.count == 1)
        return entries[0]
    }

    private func bookmarkEntry(_ node: BookmarkNode, score: Double = 1) -> HistoryFuzzyEntry {
        HistoryFuzzyEntry(bookmark: node, score: score, titlePositions: [], urlPositions: [])
    }

    // MARK: - Matching

    @Test("query must appear in order in the title or url")
    func subsequence() {
        let nodes = [link(title: "GitHub", url: "https://github.com")]
        #expect(BookmarkMatcher.hits(query: "gthb", nodes: nodes).count == 1)
        #expect(BookmarkMatcher.hits(query: "xyz", nodes: nodes).isEmpty)
        // Wrong order is not a match.
        #expect(BookmarkMatcher.hits(query: "bg", nodes: nodes).isEmpty)
    }

    @Test("matching is case-insensitive and reports byte offsets")
    func caseAndPositions() {
        let nodes = [link(title: "GitHub", url: "https://github.com")]
        let hits = BookmarkMatcher.hits(query: "GIT", nodes: nodes)
        #expect(hits.count == 1)
        // Title wins ties, so the positions land on the title's bytes.
        #expect(hits[0].titlePositions == [0, 1, 2])
        #expect(hits[0].urlPositions.isEmpty)
    }

    @Test("url-only matches report url positions")
    func urlPositions() {
        let nodes = [link(title: "Sign in", url: "https://github.com/login")]
        let hits = BookmarkMatcher.hits(query: "log", nodes: nodes)
        #expect(hits.count == 1)
        #expect(hits[0].titlePositions.isEmpty)
        #expect(hits[0].urlPositions == [19, 20, 21])
    }

    @Test("folders, url-less links and short queries never match")
    func scope() {
        let folder = BookmarkNode(id: "f", kind: .folder, title: "github stuff")
        let urlLess = BookmarkNode(id: "u", kind: .link, title: "github")
        let nodes = [folder, urlLess, link(title: "GitHub", url: "https://github.com")]
        #expect(BookmarkMatcher.hits(query: "github", nodes: nodes).count == 1)
        #expect(BookmarkMatcher.hits(query: "", nodes: nodes).isEmpty)
        #expect(BookmarkMatcher.hits(query: "g", nodes: nodes).isEmpty)
    }

    @Test("tighter match scores higher")
    func scoring() {
        let nodes = [
            link(title: "GitHub", url: "https://github.com"),
            link(title: "Git Help Understanding Branching", url: "https://example.com/x"),
        ]
        let hits = BookmarkMatcher.hits(query: "gh", nodes: nodes)
        #expect(hits.count == 2)
        let byURL = Dictionary(hits.map { ($0.node.url!, $0.score) }, uniquingKeysWith: { first, _ in first })
        #expect((byURL["https://github.com"] ?? 0) > (byURL["https://example.com/x"] ?? 0))
    }

    // MARK: - Bridging

    @Test("bookmark entry carries no visits and subtitles the full url")
    func entryBridge() {
        let entry = bookmarkEntry(link(title: "Actions", url: "https://GitHub.com/features/actions"))
        #expect(entry.url == "https://GitHub.com/features/actions")
        #expect(entry.title == "Actions")
        #expect(entry.host == "github.com")
        #expect(entry.visitCount == 0)
        #expect(entry.subtitle == "https://GitHub.com/features/actions")
        #expect(entry.isBookmarked)
    }

    @Test("decoded history rows and the search row start unflagged")
    func unflaggedByDefault() {
        #expect(!historyEntry(url: "https://example.com/x", title: "X", visits: 2, score: 1).isBookmarked)
        let engine = PredefinedSearchEngine.duckDuckGo.resolved
        #expect(HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)?.isBookmarked == false)
    }

    @Test("marking flags bookmarked urls, normalising trailing slashes")
    func marking() {
        let bookmarked: Set<String> = ["https://github.com"]
        let entries = [
            historyEntry(url: "https://github.com/", title: "GitHub", visits: 4, score: 1),
            historyEntry(url: "https://example.com/x", title: "X", visits: 4, score: 1),
        ]
        let marked = SpotlightController.markingBookmarked(entries, bookmarkedURLs: bookmarked)
        #expect(marked[0].isBookmarked)
        #expect(!marked[1].isBookmarked)
    }

    @Test("marking leaves the search row and flagged rows alone")
    func markingSkips() {
        let engine = PredefinedSearchEngine.duckDuckGo.resolved
        let search = HistoryFuzzyEntry.searchRow(query: "github.com", engine: engine)!
        let flagged = bookmarkEntry(link(title: "GitHub", url: "https://github.com"))
        let marked = SpotlightController.markingBookmarked(
            [search, flagged],
            bookmarkedURLs: ["https://other.example"]
        )
        #expect(!marked[0].isBookmarked)
        #expect(marked[1].isBookmarked)
    }

    // MARK: - Blending

    @Test("visits outrank everything, then shorter urls win")
    func ordering() {
        let history = [
            historyEntry(url: "https://example.com/a-much-longer-page", title: "Long", visits: 9, score: 1),
            historyEntry(url: "https://example.com/x", title: "Short", visits: 0, score: 50),
        ]
        let bookmarks = [bookmarkEntry(link(title: "GH", url: "https://github.com"))]
        let blended = SpotlightController.blend(history: history, bookmarks: bookmarks, limit: 12)
        #expect(blended.map(\.url) == [
            "https://example.com/a-much-longer-page",
            "https://github.com",
            "https://example.com/x",
        ])
    }

    @Test("typing github puts the bookmarked homepage above its subpages")
    func githubFirst() {
        let history = [
            historyEntry(url: "https://github.com/features/actions", title: "Actions", visits: 0, score: 9),
        ]
        let bookmarks = [bookmarkEntry(link(title: "GitHub", url: "https://github.com"), score: 1)]
        let blended = SpotlightController.blend(history: history, bookmarks: bookmarks, limit: 12)
        #expect(blended.first?.url == "https://github.com")
    }

    @Test("a url in both keeps its history row, flagged")
    func dedupe() {
        let history = SpotlightController.markingBookmarked(
            [historyEntry(url: "https://github.com/", title: "GitHub", visits: 4, score: 1)],
            bookmarkedURLs: ["https://github.com"]
        )
        let bookmarks = [bookmarkEntry(link(title: "GitHub", url: "https://github.com"), score: 99)]
        let blended = SpotlightController.blend(history: history, bookmarks: bookmarks, limit: 12)
        #expect(blended.count == 1)
        #expect(blended[0].visitCount == 4)
        #expect(blended[0].isBookmarked)
    }

    @Test("blending caps at the limit and stays deterministic on ties")
    func limitAndDeterminism() {
        let bookmarks = (0 ..< 20).map { index in
            bookmarkEntry(link(id: "b\(index)", title: "P\(index)", url: "https://example.com/p\(index)"), score: 1)
        }
        let first = SpotlightController.blend(history: [], bookmarks: bookmarks, limit: 12)
        let second = SpotlightController.blend(history: [], bookmarks: bookmarks, limit: 12)
        #expect(first.count == 12)
        #expect(first.map(\.url) == second.map(\.url))
    }
}
