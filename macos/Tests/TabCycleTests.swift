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
@testable import Whatever

/// Tab cycling: Ctrl+Tab forward, Ctrl+Shift+Tab and Cmd+Shift+Tab back,
/// everything else untouched. Pure mapping, no key events needed.
@MainActor
struct TabCycleTests {
    @Test("ctrl+tab cycles forward")
    func forward() {
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.control]) == 1)
    }

    @Test("ctrl+shift+tab and cmd+shift+tab cycle back")
    func backward() {
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.control, .shift]) == -1)
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.command, .shift]) == -1)
    }

    @Test("anything else is not tab cycling")
    func untouched() {
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: []) == nil)
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.shift]) == nil)
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.command]) == nil)
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.option]) == nil)
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.control, .command]) == nil)
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.control, .option]) == nil)
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.command, .shift, .option]) == nil)
        // Caps lock, function keys, and numeric-pad flags ride along with
        // real presses; only the watched four decide.
        #expect(BrowserCoordinator.tabCycleDirection(modifiers: [.control, .capsLock]) == 1)
    }
}
