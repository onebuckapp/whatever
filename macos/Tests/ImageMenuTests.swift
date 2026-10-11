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
import WebKit
@testable import Whatever

/// Context-menu image lookup: the script carries the click point into the
/// page and answers with the image's on-screen source, and the image menu
/// leads with "Open in New Tab" ahead of WebKit's retaken items.
@MainActor
struct ImageMenuTests {
    @Test("the script queries the click point for its image")
    func queriesImage() {
        let script = BrowserWebView.imageLookupScript(viewX: 120, viewY: 45)
        #expect(script.contains("document.elementFromPoint(x, y)"))
        #expect(script.contains("closest('img')"))
        #expect(script.contains("img.currentSrc || img.src"))
    }

    @Test("the click point reaches the script")
    func carriesPoint() {
        let script = BrowserWebView.imageLookupScript(viewX: 120.5, viewY: 45.25)
        #expect(script.contains("120.5"))
        #expect(script.contains("45.25"))
    }

    @Test("scroll and zoom are removed in-script")
    func removesScrollAndZoom() {
        let script = BrowserWebView.imageLookupScript(viewX: 10, viewY: 10)
        #expect(script.contains("window.scrollX"))
        #expect(script.contains("window.scrollY"))
        #expect(script.contains("visualViewport"))
    }

    @Test("the resolution prefers the captured source and clears it")
    func prefersCaptured() {
        let script = BrowserWebView.imageResolutionScript(viewX: 10, viewY: 10)
        #expect(script.contains(PageLinkCapture.imageVariable))
        #expect(script.contains("if (captured) return captured;"))
    }

    @Test("the capture script records the image beside the link")
    func captureRecordsImage() {
        #expect(PageLinkCapture.source.contains("closest('img')"))
        #expect(PageLinkCapture.source.contains(PageLinkCapture.imageVariable))
        #expect(PageLinkCapture.source.contains("currentSrc"))
    }

    @Test("the inserted item reads Open in New Tab")
    func openItemTitle() {
        #expect(BrowserWebView.openImageInNewTabTitle == "Open in New Tab")
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

    private func imageMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(title: "Open Image in New Window", id: "WKMenuItemIdentifierOpenImageInNewWindow"))
        menu.addItem(item(title: "Download Image", id: "WKMenuItemIdentifierDownloadImage"))
        menu.addItem(item(title: "Copy Image", id: "WKMenuItemIdentifierCopyImage"))
        return menu
    }

    @Test("image menus lead with Open in New Tab and retake WebKit's items")
    func imageMenuOrder() {
        let view = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let menu = imageMenu()
        view.willOpenMenu(menu, with: menuEvent())
        #expect(menu.items.first?.identifier == BrowserWebView.openImageInNewTabItemID)
        #expect(menu.items.first?.title == "Open in New Tab")
        // Retaken onto the view:-chosen image actions work instead of dying
        // in the declined new-view request or saving unrecorded.
        for rawID in ["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage"] {
            let retaken = menu.items.first { $0.identifier?.rawValue == rawID }
            #expect(retaken?.target as? BrowserWebView === view)
        }
        // Untouched: copy keeps WebKit's behavior.
        let copy = menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyImage" }
        #expect(copy?.target as? BrowserWebView !== view)
        // WebKit can reuse a menu object: opening twice stacks no duplicates.
        view.willOpenMenu(menu, with: menuEvent())
        #expect(menu.items.filter { $0.identifier == BrowserWebView.openImageInNewTabItemID }.count == 1)
    }

    @Test("link menus gain no image item")
    func linkMenuUntouched() {
        let view = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        menu.addItem(item(title: "Open Link in New Window", id: "WKMenuItemIdentifierOpenLinkInNewWindow"))
        view.willOpenMenu(menu, with: menuEvent())
        #expect(menu.items.allSatisfy { $0.identifier != BrowserWebView.openImageInNewTabItemID })
    }
}
