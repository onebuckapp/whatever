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
import Testing
@testable import Whatever

/// Proves the page area shrinks above the crawl bar and is fully restored
/// when the bar leaves, without a window, XPC, or the shared settings
/// document: headlines go in through the store seam and visibility through
/// the controller seam, in that order so the loader never fires.
struct CrawlLayoutTests {
    private func sampleHeadlines() -> [CrawlHeadline] {
        [
            CrawlHeadline(
                articleID: 1, site: "website.com", title: "Lorem ipsum dolor sit amet",
                url: "https://website.com/a", feedURL: "https://website.com/feed", publishedAt: 2
            ),
            CrawlHeadline(
                articleID: 2, site: "website.org", title: "Something is happening",
                url: "https://website.org/b", feedURL: "https://website.com/feed", publishedAt: 1
            ),
        ]
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
        // Flushes the controller's Combine sinks, which hop through the main
        // dispatch queue before refreshing.
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test("showing the bar shrinks the page above it")
    @MainActor
    func showShrinksPage() async throws {
        let (content, pane) = makeContent()
        let fullHeight = pane.view.frame.height
        #expect(fullHeight > 500, "test setup broken: page has no height")

        let crawl = try #require(content.crawlBarController)
        crawl.store.replaceHeadlinesForTesting(sampleHeadlines())
        crawl.forceEnabledForTesting = true
        try await settle()
        content.view.layoutSubtreeIfNeeded()

        #expect(crawl.isVisible, "bar did not enter the window")
        guard let bar = crawl.barView else { return }
        let tolerance: CGFloat = 1
        #expect(abs(pane.view.frame.minY - bar.frame.maxY) < tolerance,
                "page bottom \(pane.view.frame.minY) is not the bar top \(bar.frame.maxY)")
        #expect(abs(pane.view.frame.height - (fullHeight - crawl.occupiedHeight)) < tolerance,
                "page did not shrink by the occupied height")
    }

    @Test("hiding the bar restores the full page")
    @MainActor
    func hideRestoresPage() async throws {
        let (content, pane) = makeContent()
        let fullHeight = pane.view.frame.height
        let fullMinY = pane.view.frame.minY

        let crawl = try #require(content.crawlBarController)
        crawl.store.replaceHeadlinesForTesting(sampleHeadlines())
        crawl.forceEnabledForTesting = true
        try await settle()
        content.view.layoutSubtreeIfNeeded()
        #expect(crawl.isVisible, "bar did not enter the window")

        crawl.forceEnabledForTesting = false
        try await settle()
        content.view.layoutSubtreeIfNeeded()

        let tolerance: CGFloat = 1
        #expect(!crawl.isVisible, "bar did not leave the window")
        #expect(abs(pane.view.frame.height - fullHeight) < tolerance,
                "page height \(pane.view.frame.height) did not restore to \(fullHeight)")
        #expect(abs(pane.view.frame.minY - fullMinY) < tolerance,
                "page bottom \(pane.view.frame.minY) did not restore to \(fullMinY)")
    }

    @Test("toggling twice keeps the page intact")
    @MainActor
    func doubleToggle() async throws {
        let (content, pane) = makeContent()
        let fullHeight = pane.view.frame.height

        let crawl = try #require(content.crawlBarController)
        crawl.store.replaceHeadlinesForTesting(sampleHeadlines())
        for _ in 0..<2 {
            crawl.forceEnabledForTesting = true
            try await settle()
            content.view.layoutSubtreeIfNeeded()
            #expect(crawl.isVisible)
            crawl.forceEnabledForTesting = false
            try await settle()
            content.view.layoutSubtreeIfNeeded()
            #expect(!crawl.isVisible)
        }
        #expect(abs(pane.view.frame.height - fullHeight) < 1,
                "page height \(pane.view.frame.height) drifted from \(fullHeight) across toggles")
    }
}
