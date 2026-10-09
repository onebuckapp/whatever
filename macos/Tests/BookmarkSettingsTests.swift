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

/// Bookmarks-bar settings: defaults, legacy documents, and round trip.
struct BookmarkSettingsTests {
    @Test("the bar is hidden by default")
    func defaults() {
        #expect(AppSettings().bookmarks.showBar == false)
    }

    @Test("documents written before bookmarks existed decode to defaults")
    func legacyDecodes() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded.bookmarks.showBar == false)
    }

    @Test("a document written before the group existed still decodes")
    func legacyWithOtherGroups() throws {
        var settings = AppSettings()
        settings.feeds.crawlEnabled = true
        settings.appearance.tabCornerRadius = 4
        // An old document is a current one minus the key that did not exist
        // yet; groups themselves are written whole, so a hand-made partial
        // group is not the legacy shape.
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        object.removeValue(forKey: "bookmarks")
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.bookmarks.showBar == false)
        #expect(decoded.feeds.crawlEnabled)
        #expect(decoded.appearance.tabCornerRadius == 4)
    }

    @Test("the chosen visibility round-trips")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.bookmarks.showBar = true
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.bookmarks == settings.bookmarks)
        #expect(decoded.bookmarks.showBar)
    }
}
