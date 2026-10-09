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

/// Filter matching behind the Appearance pane's search field: every query
/// word must land in the section's title or keywords, and emptiness matches
/// everything so the pane opens unfiltered.
struct SettingsFilterTests {
    @Test("empty query matches everything")
    func emptyMatchesAll() {
        #expect(SettingsFilter.matches(query: "", haystack: "Grain"))
        #expect(SettingsFilter.matches(query: "   ", haystack: "Anything"))
    }

    @Test("matching ignores case")
    func caseInsensitive() {
        #expect(SettingsFilter.matches(query: "grain", haystack: "Grain texture film"))
        #expect(SettingsFilter.matches(query: "GRAIN", haystack: "Grain texture film"))
        #expect(!SettingsFilter.matches(query: "video", haystack: "Grain texture film"))
    }

    @Test("every word must match somewhere")
    func allWordsRequired() {
        #expect(SettingsFilter.matches(query: "current tab", haystack: "Inactive Tabs Current Tab"))
        #expect(!SettingsFilter.matches(query: "current window", haystack: "Inactive Tabs Current Tab"))
    }

    @Test("the Grain example keeps only its section")
    func grainExample() {
        #expect(SettingsFilter.matches(query: "Grain", haystack: "Grain grain texture film noise pattern"))
        #expect(!SettingsFilter.matches(query: "Grain", haystack: "Look look color colour opacity"))
        #expect(!SettingsFilter.matches(query: "Grain", haystack: "Window Background background wallpaper"))
    }
}
