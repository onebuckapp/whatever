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

/// Address bar chrome model: defaults reproduce the bar from before settings
/// owned it, and old documents decode without the new keys.
struct AddressBarTests {
    @Test("defaults stretch the field full width")
    func stretchByDefault() {
        let style = AddressBarSettings()
        #expect(style.fillsWidth)
        #expect(style.cornerRadius == 10)
        #expect(style.fieldHeight == 32)
    }

    @Test("radius caps at half the height, so the max is a pill")
    func pillCap() {
        #expect(AddressBarSettings.clampedRadius(16, forHeight: 32) == 16)
        #expect(AddressBarSettings.clampedRadius(99, forHeight: 32) == 16)
        #expect(AddressBarSettings.clampedRadius(10, forHeight: 32) == 10)
        #expect(AddressBarSettings.clampedRadius(-4, forHeight: 32) == 0)
    }

    @Test("settings round-trip and tolerate old documents")
    func storage() throws {
        var style = AddressBarSettings()
        style.fillsWidth = true
        style.cornerRadius = 16
        style.fieldHeight = 36
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(AddressBarSettings.self, from: data) == style)

        var settings = AppSettings()
        settings.addressBar = style
        let stored = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: stored).addressBar == style)

        let legacy = "{}".data(using: .utf8)!
        #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).addressBar == AddressBarSettings())
    }
}
