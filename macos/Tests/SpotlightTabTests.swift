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

/// Tab and Shift+Tab walk the searchbar dropdown with wraparound: past the
/// last row back to the first, past the first to the last. Pure rule, no
/// panel, field, or history needed.
@MainActor
struct SpotlightTabTests {
    @Test("nothing to walk consumes nothing")
    func emptyConsumesNothing() {
        #expect(SpotlightController.nextWrappingIndex(current: nil, count: 0, forward: true) == nil)
        #expect(SpotlightController.nextWrappingIndex(current: nil, count: 0, forward: false) == nil)
        #expect(SpotlightController.nextWrappingIndex(current: 0, count: 0, forward: true) == nil)
    }

    @Test("a lone row stays put in both directions")
    func singleRowStays() {
        #expect(SpotlightController.nextWrappingIndex(current: nil, count: 1, forward: true) == 0)
        #expect(SpotlightController.nextWrappingIndex(current: 0, count: 1, forward: true) == 0)
        #expect(SpotlightController.nextWrappingIndex(current: nil, count: 1, forward: false) == 0)
        #expect(SpotlightController.nextWrappingIndex(current: 0, count: 1, forward: false) == 0)
    }

    @Test("tab walks forward and wraps past the last row to the first")
    func tabWrapsForward() {
        #expect(SpotlightController.nextWrappingIndex(current: nil, count: 5, forward: true) == 0)
        #expect(SpotlightController.nextWrappingIndex(current: 0, count: 5, forward: true) == 1)
        #expect(SpotlightController.nextWrappingIndex(current: 3, count: 5, forward: true) == 4)
        #expect(SpotlightController.nextWrappingIndex(current: 4, count: 5, forward: true) == 0)
    }

    @Test("shift+tab walks backward and wraps past the first row to the last")
    func shiftTabWrapsBackward() {
        #expect(SpotlightController.nextWrappingIndex(current: nil, count: 5, forward: false) == 4)
        #expect(SpotlightController.nextWrappingIndex(current: 4, count: 5, forward: false) == 3)
        #expect(SpotlightController.nextWrappingIndex(current: 1, count: 5, forward: false) == 0)
        #expect(SpotlightController.nextWrappingIndex(current: 0, count: 5, forward: false) == 4)
    }
}
