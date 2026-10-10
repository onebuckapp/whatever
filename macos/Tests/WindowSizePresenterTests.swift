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

/// The window-size presenter's teardown contract: one notification per
/// dismissal. The card's Cancel reaches dismissal through the coordinator
/// (Mijick keys popups by type name, so a direct dismiss with our string
/// id silently does nothing), and this pins that path's endpoint.
@MainActor
struct WindowSizePresenterTests {
    @Test("dismissing notifies the owner exactly once")
    func dismissNotifies() {
        var calls = 0
        let presenter = WindowSizePresenter(container: NSView()) {
            calls += 1
        }
        presenter.dismiss()
        #expect(calls == 1)
        presenter.dismiss()
        #expect(calls == 1)
    }
}
