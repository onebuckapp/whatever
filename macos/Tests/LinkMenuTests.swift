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
