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

/// The bookmarks bar's place in the chrome: between the toolbar and the tab
/// bar, collapsing to nothing when hidden, without a window or XPC. The
/// store is marked loaded so the bar never fires a store read, and
/// visibility goes through the controller seam.
struct BookmarkBarLayoutTests {
    private func makeContent() -> (
        content: BrowserWindowContentViewController,
        toolbar: NSView,
        pane: NSViewController
    ) {
        let content = BrowserWindowContentViewController()
        content.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let toolbar = NSView()
        content.installToolbar(toolbar)
        let pane = NSViewController()
        pane.view.wantsLayer = true
        content.showChild(pane)
        content.view.layoutSubtreeIfNeeded()
        return (content, toolbar, pane)
    }

    @Test("the bar starts collapsed, between the toolbar and the tab bar")
    @MainActor
    func startsHidden() throws {
        BookmarkStore.shared.replaceNodesForTesting([])
        let (content, toolbar, _) = makeContent()
        let bar = try #require(content.bookmarkBarController)
        content.view.layoutSubtreeIfNeeded()

        #expect(!bar.isVisible)
        #expect(abs(bar.view.frame.height) < 1, "hidden bar still occupies \(bar.view.frame.height)")
        let tolerance: CGFloat = 1
        #expect(abs(bar.view.frame.maxY - toolbar.frame.minY) < tolerance,
                "bar top \(bar.view.frame.maxY) is not the toolbar bottom \(toolbar.frame.minY)")
        #expect(abs(content.tabBar.frame.maxY - bar.view.frame.minY) < tolerance,
                "tab bar top \(content.tabBar.frame.maxY) is not the bar bottom \(bar.view.frame.minY)")
    }

    @Test("showing the bar inserts it and pushes the tab bar and page down")
    @MainActor
    func showPushesChromeDown() async throws {
        BookmarkStore.shared.replaceNodesForTesting([])
        let (content, toolbar, pane) = makeContent()
        let bar = try #require(content.bookmarkBarController)
        let fullHeight = pane.view.frame.height

        bar.forceEnabledForTesting = true
        content.view.layoutSubtreeIfNeeded()

        #expect(bar.isVisible)
        let tolerance: CGFloat = 1
        #expect(abs(bar.view.frame.height - BookmarkBarView.height) < tolerance,
                "bar height \(bar.view.frame.height) is not \(BookmarkBarView.height)")
        #expect(abs(bar.view.frame.maxY - toolbar.frame.minY) < tolerance)
        #expect(abs(content.tabBar.frame.maxY - bar.view.frame.minY) < tolerance)
        #expect(abs(pane.view.frame.height - (fullHeight - BookmarkBarView.height)) < tolerance,
                "page did not shrink by the bar height")
    }

    @Test("the bar shows even with no bookmarks, so its menu can create one")
    @MainActor
    func emptyBarStillShows() async throws {
        BookmarkStore.shared.replaceNodesForTesting([])
        let (content, _, _) = makeContent()
        let bar = try #require(content.bookmarkBarController)

        bar.forceEnabledForTesting = true
        content.view.layoutSubtreeIfNeeded()

        #expect(bar.isVisible)
        #expect(bar.view.itemTitlesForTesting.isEmpty)
    }

    @Test("hiding the bar restores the chrome exactly")
    @MainActor
    func hideRestoresChrome() async throws {
        BookmarkStore.shared.replaceNodesForTesting([])
        let (content, _, pane) = makeContent()
        let bar = try #require(content.bookmarkBarController)
        let fullHeight = pane.view.frame.height

        for _ in 0..<2 {
            bar.forceEnabledForTesting = true
            content.view.layoutSubtreeIfNeeded()
            #expect(bar.isVisible)
            bar.forceEnabledForTesting = false
            content.view.layoutSubtreeIfNeeded()
            #expect(!bar.isVisible)
        }
        #expect(abs(pane.view.frame.height - fullHeight) < 1,
                "page height drifted across toggles")
    }
}
