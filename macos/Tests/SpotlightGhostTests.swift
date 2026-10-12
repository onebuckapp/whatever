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

/// The inline ghost: what Enter promises for the live text, composed from
/// the core's navigate/search hint without a panel, a field, or a store.
struct SpotlightGhostTests {
    private var engine: ResolvedSearchEngine {
        PredefinedSearchEngine.duckDuckGo.resolved
    }

    @Test("search text ghosts the engine by name")
    func searchGhost() {
        let resolved = SpotlightController.ghost(kind: "search", trimmed: "cats", engine: engine)
        // Untranslated in tests, so the msgid reads back with the name filled in.
        #expect(resolved?.text == "Search on DuckDuckGo")
        #expect(resolved?.url.absoluteString.contains("cats") == true)
    }

    @Test("domain text ghosts the visit it navigates to")
    func navigateGhost() {
        let resolved = SpotlightController.ghost(kind: "navigate", trimmed: "reddit.com", engine: engine)
        #expect(resolved?.text == "Visit https://reddit.com")
        #expect(resolved?.url.absoluteString == "https://reddit.com")
    }

    @Test("a fully typed destination ghosts nothing: it is already there")
    func sameDestinationIsSilent() {
        let resolved = SpotlightController.ghost(
            kind: "navigate", trimmed: "https://reddit.com", engine: engine)
        #expect(resolved?.text == nil)
        #expect(resolved?.url.absoluteString == "https://reddit.com")
    }

    @Test("an unknown kind searches, like any non-navigating text")
    func unknownKindSearches() {
        let resolved = SpotlightController.ghost(kind: "frobnicator", trimmed: "cats", engine: engine)
        #expect(resolved?.text == "Search on DuckDuckGo")
    }

    @Test("blank input builds no navigate ghost")
    func blankIsNil() {
        #expect(SpotlightController.ghost(kind: "navigate", trimmed: "", engine: engine) == nil)
        #expect(SpotlightController.ghost(kind: "navigate", trimmed: "   ", engine: engine) == nil)
    }

    @Test("ghost parks on whole points so the text stays sharp")
    @MainActor
    func ghostSnapsToPixels() throws {
        let field = SpotlightField(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        field.textField.stringValue = "reddit.com"
        field.setGhost("Visit https://reddit.com")
        field.layoutSubtreeIfNeeded()
        let frame = try #require(field.ghostFrameForTesting)
        // A measured width and a halved line height are fractional by
        // routine; parked as-is the ghost paints soft next to crisp input.
        #expect(frame.origin.x == frame.origin.x.rounded())
        #expect(frame.origin.y == frame.origin.y.rounded())
        // ...while staying on the field's midline.
        #expect(abs(frame.midY - field.textField.frame.midY) < 1)
    }
}
