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

/// Tab theming model: defaults preserve the existing chrome, documents
/// round-trip, and pre-theme documents decode without their keys.
struct TabThemeTests {
    @Test("a fresh theme is inert")
    func inertByDefault() {
        let theme = TabThemeConfiguration()
        #expect(theme.background.kind == .none)
        #expect(theme.background.isActive == false)
        #expect(theme.foreground == nil)
    }

    @Test("theme and appearance documents round-trip")
    func roundTrip() throws {
        var theme = TabThemeConfiguration()
        theme.background.kind = .solid
        theme.background.solid.color = BackgroundColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        theme.background.path = "/tmp/wallpaper.mp4"
        theme.foreground = BackgroundColor(red: 1, green: 1, blue: 1, alpha: 1)
        let data = try JSONEncoder().encode(theme)
        #expect(try JSONDecoder().decode(TabThemeConfiguration.self, from: data) == theme)

        var appearance = AppSettings.AppearanceSettings()
        appearance.tabTheme = theme
        let stored = try JSONEncoder().encode(appearance)
        #expect(try JSONDecoder().decode(AppSettings.AppearanceSettings.self, from: stored) == appearance)
    }

    @Test("documents written before themes decode to inert themes")
    func legacyDocuments() throws {
        let legacy = """
        {"noise": {"isEnabled": true, "opacity": 0.12, "intensity": 0.4, "contrast": 1.6, "grainScale": 1.0, "colorMode": "monochrome", "tintOpacity": 0.0, "seed": 0}}
        """.data(using: .utf8)!
        let appearance = try JSONDecoder().decode(AppSettings.AppearanceSettings.self, from: legacy)
        // Compared by behaviour, not full equality: default gradient stops
        // carry random ids, so two fresh defaults never compare equal.
        #expect(appearance.tabTheme.background.kind == .none)
        #expect(appearance.tabTheme.foreground == nil)
        #expect(appearance.activeTabTheme.background.kind == .none)
        #expect(appearance.activeTabTheme.foreground == nil)
    }
}
