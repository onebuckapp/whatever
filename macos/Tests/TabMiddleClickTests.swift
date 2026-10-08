import AppKit
import Testing
@testable import Whatever

/// Middle-click closes: a lone cell closes its tab, a group cell both members.
@MainActor
struct TabMiddleClickTests {
    private final class StubHistory: HistoryRecording {
        func record(url: URL, title: String?) {}
    }

    private func makeTab() -> BrowserTab {
        BrowserTab(privacyMode: .regular, history: StubHistory())
    }

    private func middleClick() -> NSEvent {
        NSEvent.mouseEvent(
            with: .otherMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
    }

    @Test("middle-click on a tab cell closes it")
    func loneCellCloses() {
        let item = TabBarItemView(tab: makeTab())
        var closed = false
        item.onClose = { closed = true }
        item.otherMouseDown(with: middleClick())
        #expect(closed)
    }

    @Test("middle-click on a group cell closes it")
    func groupCellCloses() {
        let cell = TabGroupCellView(leading: makeTab(), trailing: makeTab())
        var closed = false
        cell.onClose = { closed = true }
        cell.otherMouseDown(with: middleClick())
        #expect(closed)
    }

    @Test("middle-click does not arm a drag")
    func noDragArmed() {
        // Press tracking is left-button only: a middle press followed by
        // movement must not start a tab drag session.
        let item = TabBarItemView(tab: makeTab())
        var pressed = false
        item.onPress = { pressed = true }
        item.otherMouseDown(with: middleClick())
        #expect(!pressed)
    }
}
