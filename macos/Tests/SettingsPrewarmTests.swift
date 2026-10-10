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
@testable import Whatever

/// The settings prewarm loop must stop the moment the user interacts:
/// mounting a pane blocks the main thread for up to a few hundred
/// milliseconds, and a click landing inside a pane build waits for the
/// whole build before its field can focus.
@MainActor
struct SettingsPrewarmTests {
    @Test("a press cancels the prewarm loop, idempotently")
    func cancelPrewarm() {
        let id = "prewarm-\(UUID().uuidString)"
        let flag = SettingsModalCoordinator.shared.prewarmFlag(id: id)
        #expect(!flag.cancelled)
        SettingsModalCoordinator.shared.cancelPrewarm(id: id)
        #expect(flag.cancelled)
        // A second press changes nothing, and unknown ids are a no-op.
        SettingsModalCoordinator.shared.cancelPrewarm(id: id)
        SettingsModalCoordinator.shared.cancelPrewarm(id: "prewarm-missing")
        #expect(flag.cancelled)
        SettingsModalCoordinator.shared.popupDidDismiss(id: id)
    }

    @Test("flags are per card")
    func flagsArePerCard() {
        let first = SettingsModalCoordinator.shared.prewarmFlag(id: "prewarm-a-\(UUID().uuidString)")
        let second = SettingsModalCoordinator.shared.prewarmFlag(id: "prewarm-b-\(UUID().uuidString)")
        #expect(first !== second)
        #expect(!first.cancelled && !second.cancelled)
    }
}
