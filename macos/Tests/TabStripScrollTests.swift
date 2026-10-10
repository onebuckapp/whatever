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

/// Tab strip overflow: hidden scrollers, fades only at hidden edges, the
/// selection scrolling into view, and the `+` button pinned at the visible
/// trailing edge.
@MainActor
struct TabStripScrollTests {
    private final class StubHistory: HistoryRecording {
        func record(url: URL, title: String?) {}
    }

    private func makeTabs(_ count: Int) -> [BrowserTab] {
        (0..<count).map { _ in BrowserTab(privacyMode: .regular, history: StubHistory()) }
    }

    private func makeContainer(width: CGFloat = 800) -> TabBarContainerView {
        let container = TabBarContainerView(newTabAction: {})
        container.frame = NSRect(x: 0, y: 0, width: width, height: 36)
        return container
    }

    private func scrollView(in container: TabBarContainerView) -> NSScrollView {
        container.subviews.compactMap { $0 as? NSScrollView }.first!
    }

    @Test("no fades when every tab fits")
    func fadesHiddenWhenAllFit() {
        let container = makeContainer()
        let tabs = makeTabs(3)
        container.strip.setTabs(tabs, selectedTabID: tabs[0].id)
        container.layoutSubtreeIfNeeded()
        #expect(container.fadesVisibleForTesting == (false, false))
    }

    @Test("right fade appears on overflow, left stays hidden")
    func rightFadeOnOverflow() {
        let container = makeContainer()
        let tabs = makeTabs(30)
        container.strip.setTabs(tabs, selectedTabID: tabs[0].id)
        container.layoutSubtreeIfNeeded()
        #expect(container.strip.preferredWidth > container.bounds.width)
        #expect(container.fadesVisibleForTesting == (false, true))
    }

    @Test("left fade appears at the far end, right disappears")
    func fadesSwapAtFarEnd() {
        let container = makeContainer()
        let tabs = makeTabs(30)
        container.strip.setTabs(tabs, selectedTabID: tabs[0].id)
        container.layoutSubtreeIfNeeded()
        container.scrollToForTesting(1_000_000)
        container.layoutSubtreeIfNeeded()
        #expect(container.scrollOriginXForTesting > 0)
        #expect(container.fadesVisibleForTesting == (true, false))
    }

    @Test("the + button stays at the visible trailing edge when scrolled")
    func plusButtonPinned() {
        let container = makeContainer()
        let tabs = makeTabs(30)
        container.strip.setTabs(tabs, selectedTabID: tabs[0].id)
        container.layoutSubtreeIfNeeded()
        let pinned = container.newTabButtonFrameForTesting
        container.scrollToForTesting(1_000_000)
        container.layoutSubtreeIfNeeded()
        let button = container.newTabButtonFrameForTesting
        #expect(abs(button.maxX - (container.bounds.width - 4)) < 1)
        // Scrolling the strip never moves the button: same frame as at rest.
        #expect(abs(button.minX - pinned.minX) < 0.5)
        #expect(abs(button.maxX - pinned.maxX) < 0.5)
    }

    @Test("selecting an offscreen tab scrolls it into view")
    func selectionScrollsIntoView() {
        let container = makeContainer()
        let tabs = makeTabs(30)
        container.strip.setTabs(tabs, selectedTabID: tabs[0].id)
        container.layoutSubtreeIfNeeded()
        #expect(container.scrollOriginXForTesting == 0)
        container.strip.setTabs(tabs, selectedTabID: tabs.last?.id)
        container.layoutSubtreeIfNeeded()
        #expect(container.scrollOriginXForTesting > 0)
        // Back to the first tab scrolls home and clears the left fade.
        container.strip.setTabs(tabs, selectedTabID: tabs[0].id)
        container.layoutSubtreeIfNeeded()
        #expect(container.scrollOriginXForTesting == 0)
        #expect(container.fadesVisibleForTesting == (false, true))
    }

    @Test("re-setting the same selection never moves the scroll")
    func sameSelectionKeepsScroll() {
        let container = makeContainer()
        let tabs = makeTabs(30)
        container.strip.setTabs(tabs, selectedTabID: tabs.last?.id)
        container.layoutSubtreeIfNeeded()
        let origin = container.scrollOriginXForTesting
        #expect(origin > 0)
        // A repaint with the same selection — a title update, a mute flip —
        // must not yank the strip.
        container.strip.setTabs(tabs, selectedTabID: tabs.last?.id)
        container.layoutSubtreeIfNeeded()
        #expect(container.scrollOriginXForTesting == origin)
    }

    @Test("scrollers stay off: scrolling is bar-less")
    func scrollersStayHidden() {
        let container = makeContainer()
        let scroll = scrollView(in: container)
        #expect(scroll.hasHorizontalScroller == false)
        #expect(scroll.hasVerticalScroller == false)
    }

    @Test("wheel mapping: horizontal passes through, vertical rotates")
    func wheelMapping() {
        // A device speaking horizontal is trusted, precise or not.
        #expect(TabBarContainerView.stripDelta(dx: 5, dy: 0, precise: true) == 5)
        #expect(TabBarContainerView.stripDelta(dx: -3, dy: 9, precise: false) == -3)
        // Vertical rotates: wheel-down (negative) moves toward the trailing
        // tabs, wheel-up back toward the leading ones.
        #expect(TabBarContainerView.stripDelta(dx: 0, dy: -1, precise: false) == 40)
        #expect(TabBarContainerView.stripDelta(dx: 0, dy: 1, precise: false) == -40)
        // Precise vertical gestures already speak in points: no scaling.
        #expect(TabBarContainerView.stripDelta(dx: 0, dy: -7, precise: true) == 7)
        #expect(TabBarContainerView.stripDelta(dx: 0, dy: 0, precise: false) == 0)
    }

    @Test("manual scroll moves and clamps at both ends")
    func manualScrollClamps() {
        let container = makeContainer()
        let tabs = makeTabs(30)
        container.strip.setTabs(tabs, selectedTabID: tabs[0].id)
        container.layoutSubtreeIfNeeded()
        container.scrollHorizontallyForTesting(200)
        #expect(container.scrollOriginXForTesting == 200)
        container.scrollHorizontallyForTesting(-80)
        #expect(container.scrollOriginXForTesting == 120)
        // Past either end clamps instead of overshooting.
        container.scrollHorizontallyForTesting(-10_000)
        #expect(container.scrollOriginXForTesting == 0)
        container.scrollHorizontallyForTesting(10_000)
        container.layoutSubtreeIfNeeded()
        let maxX = container.strip.preferredWidth
            - scrollView(in: container).contentView.bounds.width
        #expect(container.scrollOriginXForTesting == maxX)
    }

    @Test("manual scroll is a no-op when every tab fits")
    func manualScrollRestsWhenFitting() {
        let container = makeContainer()
        let tabs = makeTabs(3)
        container.strip.setTabs(tabs, selectedTabID: tabs[0].id)
        container.layoutSubtreeIfNeeded()
        container.scrollHorizontallyForTesting(200)
        #expect(container.scrollOriginXForTesting == 0)
    }

    @Test("the strip forwards wheel events to the container")
    func wheelHandlerWired() {
        let container = makeContainer()
        #expect(container.strip.scrollWheelHandler != nil)
    }

    @Test("scrolling under a stationary cursor moves hover instead of multiplying it")
    func hoverFollowsScroll() {
        let container = makeContainer()
        let tabs = makeTabs(30)
        container.strip.setTabs(tabs, selectedTabID: tabs[0].id)
        container.layoutSubtreeIfNeeded()
        // Thirty tabs in ~760pt sit at minimum width (90pt + 4pt gap), so
        // x=150 is mid-cell and x=350 two cells later. The cursor rests at
        // the on-screen position showing strip point 150: one hover.
        container.strip.refreshHover(at: NSPoint(x: 150, y: 18))
        let first = container.strip.hoveredTabIDsForTesting
        #expect(first.count == 1)
        // The strip scrolls 200pt beneath the unmoving cursor, which now
        // shows strip point 350. Re-resolving leaves exactly one hover, on
        // a different tab — without the refresh both would paint hovered.
        container.scrollHorizontallyForTesting(200)
        container.layoutSubtreeIfNeeded()
        container.strip.refreshHover(at: NSPoint(x: 350, y: 18))
        let hovered = container.strip.hoveredTabIDsForTesting
        #expect(hovered.count == 1)
        #expect(hovered != first)
        // Off the strip clears everything.
        container.strip.refreshHover(at: nil)
        #expect(container.strip.hoveredTabIDsForTesting.isEmpty)
    }
}
