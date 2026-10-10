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

/// The bookmarks bar scrolls like the tab strip: no fades when everything
/// fits, an edge fade wherever entries hide, clamped manual scrolling, and
/// no overflow menu anywhere.
@MainActor
struct BookmarkBarScrollTests {
    private func makeNodes(_ count: Int, longTitles: Bool = false) -> [BookmarkNode] {
        (0..<count).map { i in
            BookmarkNode(
                id: "b\(i)",
                kind: .link,
                title: longTitles ? "A very long bookmark title number \(i)" : "B\(i)",
                url: "https://example.com/\(i)"
            )
        }
    }

    private func makeBar(width: CGFloat = 1200, nodes: [BookmarkNode]) -> BookmarkBarView {
        let bar = BookmarkBarView()
        bar.frame = NSRect(x: 0, y: 0, width: width, height: BookmarkBarView.height)
        bar.update(nodes: nodes)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    @Test("no fades when every entry fits")
    func fadesHiddenWhenAllFit() {
        let bar = makeBar(nodes: makeNodes(3))
        #expect(bar.fadesVisibleForTesting == (false, false))
        #expect(bar.scrollOriginXForTesting == 0)
    }

    @Test("right fade appears on overflow, left stays hidden")
    func rightFadeOnOverflow() {
        let bar = makeBar(nodes: makeNodes(30, longTitles: true))
        #expect(bar.itemsWidthForTesting > bar.bounds.width)
        #expect(bar.fadesVisibleForTesting == (false, true))
    }

    @Test("left fade appears at the far end, right disappears")
    func fadesSwapAtFarEnd() {
        let bar = makeBar(nodes: makeNodes(30, longTitles: true))
        bar.scrollToForTesting(1_000_000)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.scrollOriginXForTesting > 0)
        #expect(bar.fadesVisibleForTesting == (true, false))
    }

    @Test("manual scroll moves and clamps at both ends")
    func manualScrollClamps() {
        let bar = makeBar(nodes: makeNodes(30, longTitles: true))
        bar.scrollHorizontallyForTesting(200)
        #expect(bar.scrollOriginXForTesting == 200)
        bar.scrollHorizontallyForTesting(-80)
        #expect(bar.scrollOriginXForTesting == 120)
        bar.scrollHorizontallyForTesting(-10_000)
        #expect(bar.scrollOriginXForTesting == 0)
        bar.scrollHorizontallyForTesting(10_000)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.scrollOriginXForTesting == bar.itemsWidthForTesting - bar.bounds.width)
    }

    @Test("manual scroll is a no-op when every entry fits")
    func manualScrollRestsWhenFitting() {
        let bar = makeBar(nodes: makeNodes(3))
        bar.scrollHorizontallyForTesting(200)
        #expect(bar.scrollOriginXForTesting == 0)
    }

    @Test("widening past the overflow re-zeroes the scroll and clears fades")
    func wideningHomesScroll() {
        let bar = makeBar(nodes: makeNodes(30, longTitles: true))
        bar.scrollToForTesting(1_000_000)
        #expect(bar.scrollOriginXForTesting > 0)
        // Wide enough for thirty capped titles: no overflow left.
        bar.frame = NSRect(x: 0, y: 0, width: 8000, height: BookmarkBarView.height)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.scrollOriginXForTesting == 0)
        #expect(bar.fadesVisibleForTesting == (false, false))
    }

    @Test("entries keep their titles and order through the rebuild")
    func titlesSurvive() {
        let bar = makeBar(nodes: makeNodes(3))
        #expect(bar.itemTitlesForTesting == ["B0", "B1", "B2"])
    }
}
