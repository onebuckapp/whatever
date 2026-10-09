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

/// The tab's back/forward list, as pure value semantics. Every test here
/// drives `TabHistory` directly: it has no view, no coordinator, and no
/// WebKit, so the rules themselves are pinned without launching anything.
struct TabHistoryTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test("linear navigation appends every address")
    func linearNavigationAppends() {
        var history = TabHistory()
        history.navigate(to: url("https://website.com"))
        history.navigate(to: url("https://website.com/products"))
        history.navigate(to: url("https://website.com/products/tshirt"))
        #expect(history.urls.map(\.absoluteString) == [
            "https://website.com",
            "https://website.com/products",
            "https://website.com/products/tshirt",
        ])
        #expect(history.index == 2)
        #expect(history.currentURL?.absoluteString == "https://website.com/products/tshirt")
    }

    @Test("back walks one entry at a time to the start")
    func backWalksToStart() {
        var history = TabHistory()
        history.navigate(to: url("https://website.com"))
        history.navigate(to: url("https://website.com/products"))
        history.navigate(to: url("https://website.com/products/tshirt"))
        #expect(history.moveBack()?.absoluteString == "https://website.com/products")
        #expect(history.moveBack()?.absoluteString == "https://website.com")
        #expect(history.moveBack() == nil)
        #expect(history.canGoBack == false)
    }

    @Test("forward walks back up after going back")
    func forwardAfterBack() {
        var history = TabHistory()
        history.navigate(to: url("https://website.com"))
        history.navigate(to: url("https://website.com/products"))
        _ = history.moveBack()
        #expect(history.moveForward()?.absoluteString == "https://website.com/products")
        #expect(history.moveForward() == nil)
    }

    @Test("a new address drops forward entries")
    func newAddressDropsForward() {
        var history = TabHistory()
        history.navigate(to: url("https://a.example"))
        history.navigate(to: url("https://b.example"))
        _ = history.moveBack()
        history.navigate(to: url("https://c.example"))
        #expect(history.urls.map(\.absoluteString) == [
            "https://a.example", "https://c.example",
        ])
        #expect(history.moveForward() == nil)
    }

    @Test("committed addresses append when new and no-op when current")
    func committedAddresses() {
        var history = TabHistory()
        history.navigate(to: url("https://website.com"))
        // A scripted navigation the tab never asked for: logged.
        #expect(history.noteCommitted(url("https://website.com/products")) == true)
        #expect(history.urls.count == 2)
        // A reload or back-load of the current page: not logged twice.
        #expect(history.noteCommitted(url("https://website.com/products")) == false)
        #expect(history.urls.count == 2)
    }

    @Test("a committed bare host does not duplicate the typed one")
    func committedBareHostNoDuplicate() {
        var history = TabHistory()
        // The address bar appends what was typed; WebKit reports the commit
        // with the trailing slash it adds itself.
        history.navigate(to: url("https://website.com"))
        #expect(history.noteCommitted(url("https://website.com/")) == false)
        #expect(history.urls.count == 1)
    }

    @Test("about:blank never records")
    func blankNeverRecords() {
        var history = TabHistory()
        history.navigate(to: url("https://website.com"))
        // The teardown address a dying view is pointed at: Back must never
        // land on it, even if its commit outruns the detach.
        #expect(history.noteCommitted(url("about:blank")) == false)
        #expect(history.urls.map(\.absoluteString) == ["https://website.com"])
        #expect(history.index == 0)
        #expect(history.canGoBack == false)
    }

    @Test("dropping the current entry keeps the tab on its predecessor")
    func dropCurrent() {
        var history = TabHistory()
        history.navigate(to: url("https://search.example/"))
        history.navigate(to: url("https://tracker.example/l/?uddg=https://shop.example/"))
        #expect(history.drop(url("https://tracker.example/l/?uddg=https://shop.example/")) == true)
        #expect(history.urls.map(\.absoluteString) == ["https://search.example/"])
        #expect(history.index == 0)
        #expect(history.currentURL?.absoluteString == "https://search.example/")
    }

    @Test("dropping a middle entry shifts the index onto the next page")
    func dropMiddle() {
        var history = TabHistory()
        history.navigate(to: url("https://a.example"))
        history.navigate(to: url("https://tracker.example/"))
        history.navigate(to: url("https://b.example"))
        #expect(history.drop(url("https://tracker.example/")) == true)
        #expect(history.urls.map(\.absoluteString) == [
            "https://a.example", "https://b.example",
        ])
        #expect(history.index == 1)
        #expect(history.currentURL?.absoluteString == "https://b.example")
    }

    @Test("dropping a missing entry changes nothing")
    func dropMissing() {
        var history = TabHistory()
        history.navigate(to: url("https://a.example"))
        #expect(history.drop(url("https://gone.example/")) == false)
        #expect(history.urls.map(\.absoluteString) == ["https://a.example"])
        #expect(history.index == 0)
    }

    @Test("dropping the only entry empties the list")
    func dropSole() {
        var history = TabHistory()
        history.navigate(to: url("https://tracker.example/"))
        #expect(history.drop(url("https://tracker.example/")) == true)
        #expect(history.urls.isEmpty)
        #expect(history.index == -1)
        #expect(history.canGoBack == false)
    }

    @Test("a committed address drops forward entries like a navigation")
    func committedDropsForward() {
        var history = TabHistory()
        history.navigate(to: url("https://a.example"))
        history.navigate(to: url("https://b.example"))
        _ = history.moveBack()
        #expect(history.noteCommitted(url("https://c.example")) == true)
        #expect(history.urls.map(\.absoluteString) == [
            "https://a.example", "https://c.example",
        ])
    }

    @Test("restored state clamps the index into the list")
    func restoreClampsIndex() {
        #expect(TabHistory(urls: [], index: 5).index == -1)
        #expect(TabHistory(urls: [url("https://a.example")], index: 9).index == 0)
        #expect(TabHistory(
            urls: [url("https://a.example"), url("https://b.example")],
            index: 1
        ).index == 1)
    }
}
