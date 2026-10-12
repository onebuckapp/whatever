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

import AppKit
import Foundation
import Testing
@testable import Whatever

/// Chrome layout positions: tab strip above or below the page, crawl bar
/// below the tabs or above the page. Model decoding first (old documents
/// lack both keys), then the constraint chain on a headless content
/// controller through the layout seam — never the shared settings document.
@MainActor
struct ChromeLayoutTests {
    @Test("a tab position missing from the document stays on top")
    func tabPositionDefaultsTop() throws {
        let data = "{\"tabShape\": \"pills\"}".data(using: .utf8)!
        let appearance = try JSONDecoder().decode(AppSettings.AppearanceSettings.self, from: data)
        #expect(appearance.tabShape == .pills)
        #expect(appearance.tabPosition == .top)
    }

    @Test("a stored tab position decodes and round-trips")
    func tabPositionRoundTrips() throws {
        var appearance = AppSettings.AppearanceSettings()
        appearance.tabPosition = .bottom
        let stored = try JSONEncoder().encode(appearance)
        #expect(try JSONDecoder().decode(AppSettings.AppearanceSettings.self, from: stored) == appearance)
    }

    @Test("a crawl position missing from the document stays at the bottom")
    func crawlPositionDefaultsBottom() throws {
        let data = "{\"crawlEnabled\": true}".data(using: .utf8)!
        let feeds = try JSONDecoder().decode(AppSettings.FeedSettings.self, from: data)
        #expect(feeds.crawlEnabled == true)
        #expect(feeds.crawlPosition == .bottom)
        // The rest of the group survives the tolerant read.
        #expect(feeds.crawlSpeed == 60)
        #expect(feeds.crawlBarHeight == 28)
    }

    @Test("a stored crawl position decodes and round-trips")
    func crawlPositionRoundTrips() throws {
        var feeds = AppSettings.FeedSettings()
        feeds.crawlPosition = .top
        let stored = try JSONEncoder().encode(feeds)
        #expect(try JSONDecoder().decode(AppSettings.FeedSettings.self, from: stored) == feeds)
    }

    @Test("a document with a feeds group but no crawl key still decodes")
    func feedsGroupWithoutCrawlKey() throws {
        let document = "{\"feeds\": {\"crawlEnabled\": true}}".data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: document)
        #expect(settings.feeds.crawlEnabled == true)
        #expect(settings.feeds.crawlPosition == .bottom)
    }

    /// Builds a content controller with a determined top (dummy toolbar) and
    /// one shown child, laid out at a fixed size without a window: windowed
    /// layout hangs in this environment's window-server session, while the
    /// pin math under test is window-independent.
    private func makeContent() -> (BrowserWindowContentViewController, NSViewController) {
        let content = BrowserWindowContentViewController()
        content.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        content.installToolbar(NSView())
        let pane = NSViewController()
        pane.view.wantsLayer = true
        content.showChild(pane)
        content.view.layoutSubtreeIfNeeded()
        return (content, pane)
    }

    private func settle() async throws {
        // Flushes the Combine sinks, which hop through the main dispatch
        // queue before re-pinning.
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test("tabs below the page hang the page off the toolbar strip")
    func tabsBelowPage() async throws {
        let (content, pane) = makeContent()
        let tolerance: CGFloat = 1
        // Default first: the page hangs below the tabs.
        #expect(abs(pane.view.frame.maxY - content.tabBar.frame.minY) < tolerance)

        content.chromeLayoutForTesting = .init(tabsAtBottom: true, crawlAtTop: false)
        try await settle()
        content.view.layoutSubtreeIfNeeded()
        // The strip moved under the page, flush against it.
        #expect(abs(pane.view.frame.minY - content.tabBar.frame.maxY) < tolerance)
        // …and against the window bottom with no crawl bar showing.
        #expect(abs(content.tabBar.frame.minY) < tolerance)

        content.chromeLayoutForTesting = nil
        try await settle()
        content.view.layoutSubtreeIfNeeded()
        #expect(abs(pane.view.frame.maxY - content.tabBar.frame.minY) < tolerance)
    }

    @Test("a top crawl bar hangs the page off it")
    func crawlAbovePage() async throws {
        let (content, pane) = makeContent()
        let crawl = try #require(content.crawlBarController)
        crawl.store.replaceHeadlinesForTesting([
            CrawlHeadline(
                articleID: 1, site: "website.com", title: "Lorem ipsum dolor sit amet",
                url: "https://website.com/a", feedURL: "https://website.com/feed", isSaved: false, publishedAt: 2
            ),
        ])
        crawl.forceEnabledForTesting = true
        content.chromeLayoutForTesting = .init(tabsAtBottom: false, crawlAtTop: true)
        try await settle()
        content.view.layoutSubtreeIfNeeded()

        #expect(crawl.isVisible, "bar did not enter the window")
        guard let bar = crawl.barView else { return }
        let tolerance: CGFloat = 1
        // Tabs above the page as usual, but the page hangs off the bar.
        #expect(abs(pane.view.frame.maxY - content.tabBar.frame.minY) < tolerance)
        // The bar keeps a tightened gap below it where the tabs sit directly
        // under it: the strip carries its own top breathing room.
        #expect(abs((bar.frame.minY - content.tabBar.frame.maxY) - BrowserWindowContentViewController.crawlTabsGap) < tolerance,
                "tab bar top \(content.tabBar.frame.maxY) is not \(BrowserWindowContentViewController.crawlTabsGap) below the bar bottom \(bar.frame.minY)")
    }

    @Test("tabs below and crawl below stack page, tabs, crawl")
    func tabsBelowCrawlBelow() async throws {
        let (content, pane) = makeContent()
        let crawl = try #require(content.crawlBarController)
        crawl.store.replaceHeadlinesForTesting([
            CrawlHeadline(
                articleID: 1, site: "website.com", title: "Lorem ipsum dolor sit amet",
                url: "https://website.com/a", feedURL: "https://website.com/feed", isSaved: false, publishedAt: 2
            ),
        ])
        crawl.forceEnabledForTesting = true
        content.chromeLayoutForTesting = .init(tabsAtBottom: true, crawlAtTop: false)
        try await settle()
        content.view.layoutSubtreeIfNeeded()

        #expect(crawl.isVisible, "bar did not enter the window")
        guard let bar = crawl.barView else { return }
        let tolerance: CGFloat = 1
        #expect(abs(pane.view.frame.minY - content.tabBar.frame.maxY) < tolerance,
                "page bottom \(pane.view.frame.minY) is not the tab bar top \(content.tabBar.frame.maxY)")
        #expect(abs(content.tabBar.frame.minY - bar.frame.maxY) < tolerance,
                "tab bar bottom \(content.tabBar.frame.minY) is not the bar top \(bar.frame.maxY)")
    }

    @Test("tabs below and crawl above stack crawl, page, tabs with the bar gap")
    func tabsBelowCrawlAbove() async throws {
        let (content, pane) = makeContent()
        let crawl = try #require(content.crawlBarController)
        crawl.store.replaceHeadlinesForTesting([
            CrawlHeadline(
                articleID: 1, site: "website.com", title: "Lorem ipsum dolor sit amet",
                url: "https://website.com/a", feedURL: "https://website.com/feed", isSaved: false, publishedAt: 2
            ),
        ])
        crawl.forceEnabledForTesting = true
        content.chromeLayoutForTesting = .init(tabsAtBottom: true, crawlAtTop: true)
        try await settle()
        content.view.layoutSubtreeIfNeeded()

        #expect(crawl.isVisible, "bar did not enter the window")
        guard let bar = crawl.barView else { return }
        let tolerance: CGFloat = 1
        // The page hangs off the bar, a gap below it, and the tabs sit under
        // the page flush against the window bottom.
        #expect(abs((bar.frame.minY - pane.view.frame.maxY) - BrowserWindowContentViewController.crawlGap) < tolerance,
                "page top \(pane.view.frame.maxY) is not \(BrowserWindowContentViewController.crawlGap) below the bar bottom \(bar.frame.minY)")
        #expect(abs(pane.view.frame.minY - content.tabBar.frame.maxY) < tolerance,
                "page bottom \(pane.view.frame.minY) is not the tab bar top \(content.tabBar.frame.maxY)")
        #expect(abs(content.tabBar.frame.minY) < tolerance,
                "tab bar bottom \(content.tabBar.frame.minY) is not the window bottom")
    }

    @Test("pills below the page float the strip up by the band inset")
    func tabsBelowPillsFloatsStrip() async throws {
        let (content, pane) = makeContent()
        content.chromeLayoutForTesting = .init(tabsAtBottom: true, crawlAtTop: false, tabShape: .pills)
        try await settle()
        content.view.layoutSubtreeIfNeeded()
        let tolerance: CGFloat = 1
        // The strip rides up by the pill band's top inset, so pill tops land
        // where attached tops sit; the page still hangs off the strip top.
        #expect(abs(content.tabBar.frame.minY - BrowserWindowContentViewController.pillsLift) < tolerance,
                "tab bar bottom \(content.tabBar.frame.minY) is not the pills lift \(BrowserWindowContentViewController.pillsLift) off the window bottom")
        #expect(abs(pane.view.frame.minY - content.tabBar.frame.maxY) < tolerance,
                "page bottom \(pane.view.frame.minY) is not the tab bar top \(content.tabBar.frame.maxY)")

        // Attached stays pinned flush against the window bottom.
        content.chromeLayoutForTesting = .init(tabsAtBottom: true, crawlAtTop: false, tabShape: .attached)
        try await settle()
        content.view.layoutSubtreeIfNeeded()
        #expect(abs(content.tabBar.frame.minY) < tolerance,
                "attached tab bar bottom \(content.tabBar.frame.minY) is not the window bottom")
    }

    @Test("the page card floats, except under attached cells below the page")
    func pageBottomInset() {
        // Attached below: flush, so the square cell edge meets the page.
        #expect(BrowserPaneController.pageBottomInset(tabPosition: .bottom, tabShape: .attached) == 0)
        // Pills below float higher than every other edge.
        #expect(BrowserPaneController.pageBottomInset(tabPosition: .bottom, tabShape: .pills) == 7)
        // Above the page the strip meets its top, not its bottom.
        #expect(BrowserPaneController.pageBottomInset(tabPosition: .top, tabShape: .attached) == 6)
        #expect(BrowserPaneController.pageBottomInset(tabPosition: .top, tabShape: .pills) == 6)
    }
}
