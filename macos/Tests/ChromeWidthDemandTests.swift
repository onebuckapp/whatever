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
import SwiftUI
import Testing
@testable import Whatever

/// The window must never grow to fit its chrome: the tab strip lays itself
/// out by hand, and the ticker's ideal width follows its headlines, so any
/// autoresizing snapshot or unsuppressed content demand ratchets the window
/// wider on pages with long titles — and it can never shrink back.
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

    @Test("ticker content never sizes the bar")
    func tickerDemoted() async throws {
        // Held for the test's life: the controller keeps its container
        // weakly, and a temporary would vanish before installing.
        let container = NSView()
        let controller = CrawlBarController(container: container)
        controller.forceEnabledForTesting = true
        controller.store.replaceHeadlinesForTesting([
            CrawlHeadline(
                articleID: 1, site: "website.com", title: "Lorem ipsum dolor sit amet",
                url: "https://website.com/a", feedURL: "https://website.com/feed",
                isSaved: false, publishedAt: 2
            ),
        ])
        // The headlines publisher hops through the main queue before the
        // controller refreshes and installs the bar.
        try await Task.sleep(nanoseconds: 300_000_000)
        guard let host = findTickerHost(in: controller.barView) else {
            Issue.record("crawl bar never installed its hosting view")
            return
        }
        #expect(host.contentHuggingPriority(for: .horizontal) == .defaultLow)
        #expect(host.contentCompressionResistancePriority(for: .horizontal) == .defaultLow)
    }

    private func findTickerHost(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSHostingView<CrawlTickerView> { return view }
        for subview in view.subviews {
            if let found = findTickerHost(in: subview) { return found }
        }
        return nil
    }
}
