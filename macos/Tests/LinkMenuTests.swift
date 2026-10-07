import Foundation
import Testing
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
}
