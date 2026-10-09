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

/// The omnibox search row: first result, live text, engine destination.
struct SpotlightSearchRowTests {
    private var engine: ResolvedSearchEngine {
        PredefinedSearchEngine.duckDuckGo.resolved
    }

    @Test("row names the typed text")
    func namesQuery() {
        let row = HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)
        #expect(row?.title == "Search for \"cats\"")
        #expect(row?.isSearchRow == true)
    }

    @Test("row keeps a stable identity while typing")
    func stableID() {
        let first = HistoryFuzzyEntry.searchRow(query: "ca", engine: engine)
        let second = HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)
        #expect(first?.id == HistoryFuzzyEntry.searchRowID)
        #expect(second?.id == HistoryFuzzyEntry.searchRowID)
    }

    @Test("row navigates through the address parser")
    func parserDestination() {
        let search = HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)
        #expect(search?.url.contains("cats") == true)
        #expect(search?.host == engine.title)
        // URL-looking text still goes direct, exactly as Enter would.
        let direct = HistoryFuzzyEntry.searchRow(query: "example.com", engine: engine)
        #expect(direct?.url == "https://example.com")
    }

    @Test("blank query builds no row")
    func blankIsNil() {
        #expect(HistoryFuzzyEntry.searchRow(query: "", engine: engine) == nil)
        #expect(HistoryFuzzyEntry.searchRow(query: "   ", engine: engine) == nil)
    }

    @Test("row renders plainly: no visits, no highlights")
    func plainRow() {
        let row = HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)
        #expect(row?.visitCount == 0)
        #expect(row?.titleHighlight.isEmpty == true)
        #expect(row?.urlHighlight.isEmpty == true)
    }
}
