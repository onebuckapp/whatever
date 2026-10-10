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

/// The window must never grow to fit its chrome: the tab strip lays itself
/// out by hand, and the crawl ticker is pinned directly with no content-sized
/// hosting wrapper, so no chrome view may carry a required width demand wider
/// than the window. The growth was real — SwiftUI's representable platform
/// host kept a required frame-width (`NSAutoresizingMaskLayoutConstraint` on
/// `PlatformViewHost<PlatformViewRepresentableAdaptor<CrawlTickerView>>`)
/// that AppKit satisfied by growing the window — which is why the ticker must
/// stay hosted directly.
@MainActor
struct ChromeWidthDemandTests {
    @Test("strip and its scroll view stay out of Auto Layout's hands")
    func stripManualLayout() {
        let container = TabBarContainerView(newTabAction: {})
        #expect(container.strip.translatesAutoresizingMaskIntoConstraints == false)
        let scrollers = container.subviews.compactMap { $0 as? NSScrollView }
        #expect(scrollers.count == 1)
        #expect(scrollers[0].translatesAutoresizingMaskIntoConstraints == false)
    }

    @Test("crawl bar hosts the ticker directly, no SwiftUI in between")
    func tickerHostedDirectly() async throws {
        // Held for the test's life: the controller keeps its container
        // weakly, and a temporary would vanish before installing.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1490, height: 900))
        let controller = CrawlBarController(container: container)
        controller.forceEnabledForTesting = true
        controller.store.replaceHeadlinesForTesting(sampleHeadlines())
        // The headlines publisher hops the main queue before the controller
        // refreshes and installs the bar.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(controller.barView is CrawlTickerNSView)
        #expect(findHostingView(in: container) == nil)
    }

    @Test("crawl bar never demands more than its container")
    func crawlNeverOutgrowsContainer() async throws {
        // Held for the test's life: the controller keeps its container
        // weakly, and a temporary would vanish before installing.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1490, height: 900))
        let controller = CrawlBarController(container: container)
        controller.forceEnabledForTesting = true
        // A pass of long titles wide enough that one full bitmap pass
        // (~3.5k pt) dwarfs the container: exactly the real-world shape
        // that grew the window to bitmap width.
        let headlines = (0..<15).map { i in
            CrawlHeadline(
                articleID: Int64(i), site: "website\(i).com",
                title: "Headline \(i): " + String(repeating: "breaking story text ", count: 6),
                url: "https://website\(i).com/a\(i)",
                feedURL: "https://website\(i).com/feed",
                isSaved: false, publishedAt: Int64(100 - i)
            )
        }
        controller.store.replaceHeadlinesForTesting(headlines)
        // The headlines publisher hops the main queue before the controller
        // refreshes, installs, and renders the strip.
        try await Task.sleep(nanoseconds: 400_000_000)
        container.layoutSubtreeIfNeeded()

        guard let ticker = controller.barView else {
            Issue.record("crawl bar never installed its ticker")
            return
        }
        // The ticker must sit inside its pins, not at bitmap width.
        #expect(
            ticker.frame.width <= 1490,
            "crawl ticker is \(ticker.frame.width) wide in a 1490 container")
        // And widening it must not stick as a demand: after a transient
        // resize the bar is free to shrink again, which is exactly what the
        // SwiftUI host's required frame-width broke.
        container.setFrameSize(NSSize(width: 2400, height: 900))
        container.layoutSubtreeIfNeeded()
        container.setFrameSize(NSSize(width: 1490, height: 900))
        container.layoutSubtreeIfNeeded()
        #expect(
            ticker.frame.width <= 1490,
            "crawl ticker kept \(ticker.frame.width) after the container shrank")
    }

    @Test("bookmarks bar never demands more than its container")
    func bookmarkBarNeverOutgrowsContainer() {
        // Held for the test's life: the controller keeps its container
        // weakly, and a temporary would vanish before installing.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1490, height: 900))
        let store = BookmarkStore()
        store.persistEnabled = false
        // Long titles wide enough that the full row dwarfs the container.
        store.replaceNodesForTesting((0..<30).map { i in
            BookmarkNode(
                id: "b\(i)",
                kind: .link,
                title: "A very long bookmark title number \(i)",
                url: "https://example.com/\(i)"
            )
        })
        let controller = BookmarkBarController(container: container, store: store)
        controller.forceEnabledForTesting = true
        container.layoutSubtreeIfNeeded()

        let bar = controller.view
        #expect(
            bar.frame.width <= 1490,
            "bookmarks bar is \(bar.frame.width) wide in a 1490 container")
        // Overflow scrolls under a fade instead of a chevron menu now.
        #expect(controller.view.fadesVisibleForTesting == (false, true))
        // And widening must not stick as a demand: after a transient resize
        // the bar is free to shrink again.
        container.setFrameSize(NSSize(width: 2400, height: 900))
        container.layoutSubtreeIfNeeded()
        container.setFrameSize(NSSize(width: 200, height: 900))
        container.layoutSubtreeIfNeeded()
        #expect(
            bar.frame.width <= 200,
            "bookmarks bar kept \(bar.frame.width) after the container shrank")
        // The row itself may exceed the bar; it must be clipped, not forced.
        #expect(controller.view.itemsWidthForTesting > 200)
    }

    private func sampleHeadlines() -> [CrawlHeadline] {
        [
            CrawlHeadline(
                articleID: 1, site: "website.com", title: "Lorem ipsum dolor sit amet",
                url: "https://website.com/a", feedURL: "https://website.com/feed",
                isSaved: false, publishedAt: 2
            ),
        ]
    }

    /// By name rather than by type: the point is "no SwiftUI hosting at all
    /// in this subtree", which should outlive any particular generic.
    private func findHostingView(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("NSHostingView") { return view }
        for subview in view.subviews {
            if let found = findHostingView(in: subview) { return found }
        }
        return nil
    }
}
