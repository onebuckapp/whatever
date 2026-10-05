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
