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

    private func menuEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func item(title: String, id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        return item
    }

    private func view() -> BrowserWebView {
        BrowserWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: WKWebViewConfiguration())
    }

    private func linkMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(title: "Open Link", id: "WKMenuItemIdentifierOpenLink"))
        menu.addItem(item(title: "Open Link in New Window", id: "WKMenuItemIdentifierOpenLinkInNewWindow"))
        menu.addItem(item(title: "Copy Link", id: "WKMenuItemIdentifierCopyLink"))
        return menu
    }

    @Test("link menus put Share as QR Code after the open items and hide capture")
    @MainActor
    func linkMenuOrder() {
        let menu = linkMenu()
        view().willOpenMenu(menu, with: menuEvent())
        let titles = menu.items.map(\.title)
        #expect(titles == [
            "Open Link in New Tab",
            "Open Link in New Window",
            "Share as QR Code",
            "Copy Link",
        ])
        #expect(menu.items.allSatisfy { $0.identifier != BrowserWebView.fullScreenCaptureItemID })
    }

    @Test("page menus lead with Share as QR Code directly followed by the capture")
    @MainActor
    func pageMenuOrder() {
        let menu = NSMenu()
        view().willOpenMenu(menu, with: menuEvent())
        #expect(menu.items.count == 2)
        #expect(menu.items[0].identifier == BrowserWebView.generateQRCodeItemID)
        #expect(menu.items[0].title == "Share as QR Code")
        #expect(menu.items[1].identifier == BrowserWebView.fullScreenCaptureItemID)
        #expect(menu.items[1].title == "Full Screen Capture")
    }

    @Test("reused menus relayout when the menu kind changes")
    @MainActor
    func reusedMenuRelayouts() {
        let menu = linkMenu()
        let first = view()
        first.willOpenMenu(menu, with: menuEvent())
        #expect(menu.items.filter { $0.identifier == BrowserWebView.generateQRCodeItemID }.count == 1)
        // Reused for a page: WebKit swaps its items out, ours lay out fresh.
        menu.items.filter {
            $0.identifier?.rawValue.hasPrefix("WKMenuItemIdentifier") ?? false
        }.forEach(menu.removeItem)
        view().willOpenMenu(menu, with: menuEvent())
        #expect(menu.items.first?.identifier == BrowserWebView.generateQRCodeItemID)
        #expect(menu.items.contains { $0.identifier == BrowserWebView.fullScreenCaptureItemID })
        #expect(menu.items.filter { $0.identifier == BrowserWebView.generateQRCodeItemID }.count == 1)
        // And back to a link: the capture leaves again, nothing stacks.
        menu.addItem(item(title: "Open Link", id: "WKMenuItemIdentifierOpenLink"))
        view().willOpenMenu(menu, with: menuEvent())
        #expect(menu.items.filter { $0.identifier == BrowserWebView.generateQRCodeItemID }.count == 1)
        #expect(menu.items.allSatisfy { $0.identifier != BrowserWebView.fullScreenCaptureItemID })
    }

    @Test("developer extras turn on for the inspector")
    @MainActor
    func developerExtrasEnabled() {
        let configuration = WKWebViewConfiguration()
        WebViewFactory.enableDeveloperExtras(on: configuration)
        #expect(configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool == true)
    }
}
