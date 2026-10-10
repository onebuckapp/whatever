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

import Testing
@testable import Whatever

/// Tab-walk through the Your Engines add form: forward and backward with
/// wraparound, and Tab with no field focused is not the form's to swallow.
struct EngineFormTests {
    @Test("tab walks name, address, query item and wraps")
    func walksForward() {
        #expect(SearchSettingsView.nextField(after: .name) == .address)
        #expect(SearchSettingsView.nextField(after: .address) == .queryItem)
        #expect(SearchSettingsView.nextField(after: .queryItem) == .name)
    }

    @Test("shift+tab walks back and wraps")
    func walksBackward() {
        #expect(SearchSettingsView.previousField(before: .name) == .queryItem)
        #expect(SearchSettingsView.previousField(before: .queryItem) == .address)
        #expect(SearchSettingsView.previousField(before: .address) == .name)
    }

    @Test("no focused field stays unfocused")
    func nilStaysNil() {
        #expect(SearchSettingsView.nextField(after: nil) == nil)
        #expect(SearchSettingsView.previousField(before: nil) == nil)
    }
}
