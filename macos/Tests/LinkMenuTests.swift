import Foundation
import Testing
import WebKit
@testable import Whatever

/// Context-menu link lookup: the script carries the click point into the
/// page and answers with the anchor's resolved address, or null.
struct LinkMenuTests {
    @Test("the script queries the click point for its anchor")
    func queriesAnchor() {
        let script = BrowserWebView.linkLookupScript(viewX: 120, viewY: 45)
        #expect(script.contains("document.elementFromPoint(x, y)"))
        #expect(script.contains("closest('a[href]')"))
        #expect(script.contains("return a ? a.href : null"))
    }

    @Test("the click point reaches the script")
    func carriesPoint() {
        let script = BrowserWebView.linkLookupScript(viewX: 120.5, viewY: 45.25)
        #expect(script.contains("120.5"))
        #expect(script.contains("45.25"))
    }

    @Test("scroll and zoom are removed in-script")
    func removesScrollAndZoom() {
        let script = BrowserWebView.linkLookupScript(viewX: 10, viewY: 10)
        #expect(script.contains("window.scrollX"))
        #expect(script.contains("window.scrollY"))
        #expect(script.contains("visualViewport"))
    }

    @Test("a fresh press beats the cursor")
    func freshPressWins() {
        let now = Date()
        let point = BrowserWebView.menuResolutionPoint(
            press: NSPoint(x: 10, y: 20),
            pressedAt: now,
            cursor: NSPoint(x: 30, y: 40),
            now: now
        )
        #expect(point == NSPoint(x: 10, y: 20))
    }

    @Test("a stale press is ignored in favor of the cursor")
    func stalePressLoses() {
        let now = Date()
        let point = BrowserWebView.menuResolutionPoint(
            press: NSPoint(x: 10, y: 20),
            pressedAt: now.addingTimeInterval(-30),
            cursor: NSPoint(x: 30, y: 40),
            now: now
        )
        #expect(point == NSPoint(x: 30, y: 40))
    }

    @Test("no press and no cursor means no point")
    func nothingMeansNil() {
        #expect(BrowserWebView.menuResolutionPoint(press: nil, pressedAt: nil, cursor: nil) == nil)
        #expect(
            BrowserWebView.menuResolutionPoint(
                press: nil, pressedAt: nil, cursor: NSPoint(x: 1, y: 2)) == NSPoint(x: 1, y: 2))
    }

    @Test("the retargeted open item says New Tab")
    func openItemTitle() {
        #expect(BrowserWebView.openLinkInNewTabTitle == "Open Link in New Tab")
    }

    @Test("developer extras turn on for the inspector")
    @MainActor
    func developerExtrasEnabled() {
        let configuration = WKWebViewConfiguration()
        WebViewFactory.enableDeveloperExtras(on: configuration)
        #expect(configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool == true)
    }
}
