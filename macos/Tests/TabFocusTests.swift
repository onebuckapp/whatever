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

/// Tab switches move keyboard focus to the new tab's page — but only when
/// focus was in page content. A parked page keeps its views in the
/// hierarchy, so without the move the old tab keeps eating keys (space
/// pausing its video while looking at another tab). Focus in chrome
/// (address field, find bar, cards) stays put.
@MainActor
struct TabFocusTests {
    @Test("focus in any page follows the switch")
    func pageFocusMoves() {
        #expect(BrowserWindowController.focusWasInPageContent(WKWebView()) == true)
    }

    @Test("focus in chrome stays put")
    func chromeFocusStays() {
        #expect(BrowserWindowController.focusWasInPageContent(nil) == false)
        #expect(BrowserWindowController.focusWasInPageContent(NSView()) == false)
        #expect(BrowserWindowController.focusWasInPageContent(NSTextField()) == false)
        #expect(BrowserWindowController.focusWasInPageContent(NSButton()) == false)
    }
}
