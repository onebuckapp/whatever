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

/// Frameless clicks (`target="_blank"`, `window.open`, ⌘/⇧-clicks) route by
/// intent: a bare `_blank` left-click — the shape search engines use for
/// result links — stays in the current tab so Back keeps working, while
/// explicit new-tab intent and scripted popups still open tabs.
struct NavigationPopupTests {
    @Test("a bare blank left-click stays in the tab")
    func bareBlankStays() {
        #expect(NavigationPolicy.opensNewTab(
            navigationType: .linkActivated,
            modifierFlags: [],
            targetFrameIsNil: true
        ) == false)
    }

    @Test("modified clicks open tabs")
    func modifiedClicksPop() {
        #expect(NavigationPolicy.opensNewTab(
            navigationType: .linkActivated,
            modifierFlags: .command,
            targetFrameIsNil: true
        ) == true)
        #expect(NavigationPolicy.opensNewTab(
            navigationType: .linkActivated,
            modifierFlags: .shift,
            targetFrameIsNil: true
        ) == true)
    }

    @Test("scripted popups still open tabs")
    func scriptedWindowOpenPops() {
        #expect(NavigationPolicy.opensNewTab(
            navigationType: .other,
            modifierFlags: [],
            targetFrameIsNil: true
        ) == true)
    }

    @Test("framed actions and back-forward never pop")
    func framedNeverPops() {
        #expect(NavigationPolicy.opensNewTab(
            navigationType: .linkActivated,
            modifierFlags: .command,
            targetFrameIsNil: false
        ) == false)
        #expect(NavigationPolicy.opensNewTab(
            navigationType: .backForward,
            modifierFlags: [],
            targetFrameIsNil: true
        ) == false)
    }
}
