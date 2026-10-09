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

/// The popup's settings escape hatch: tapping it must reach the owner even
/// though trading the card for settings dismisses the card first.
struct AdBlockPopupManageTests {
    @Test("manage tap fires after the dismiss clears handlers")
    @MainActor
    func manageFiresAfterDismiss() {
        var fired = false
        let presenter = AdBlockPopupPresenter(container: NSView()) {
            fired = true
        }
        presenter.manage()
        #expect(fired)
    }

    @Test("manage tap fires only once")
    @MainActor
    func manageFiresOnce() {
        var count = 0
        let presenter = AdBlockPopupPresenter(container: NSView()) {
            count += 1
        }
        presenter.manage()
        presenter.manage()
        #expect(count == 1)
    }
}
