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

/// The panel watches the pointer leaving it, so a hover-placed highlight
/// does not stick around for Enter after the mouse is gone. The exit event
/// itself needs a window, which headless tests cannot provide; the watcher
/// registration does not.
@MainActor
struct SpotlightHoverTests {
    @Test("the panel installs exactly one pointer-exit watcher")
    func hoverExitTracking() {
        let dropdown = SpotlightDropdown(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        dropdown.updateTrackingAreas()
        dropdown.updateTrackingAreas()
        let exits = dropdown.trackingAreas.filter { $0.options.contains(.mouseEnteredAndExited) }
        #expect(exits.count == 1)
    }
}
