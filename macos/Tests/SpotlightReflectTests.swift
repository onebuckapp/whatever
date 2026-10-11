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

/// Keyboard navigation mirrors the highlighted row into the field: history
/// rows fill their URL, the synthetic search row restores the typed query.
/// Pure rule, no panel, field, or history needed.
@MainActor
struct SpotlightReflectTests {
    private var engine: ResolvedSearchEngine {
        PredefinedSearchEngine.duckDuckGo.resolved
    }

    private func historyEntry() throws -> HistoryFuzzyEntry {
        let entry = try #require(HistoryEntry.decodeList(Data(
            """
            [{"id":"1","url":"https://github.com","title":"GitHub","host":"github.com","firstVisited":0,"lastVisited":0,"visitCount":5}]
            """.utf8
        )).first)
        return HistoryFuzzyEntry(entry)
    }

    @Test("a history row fills its URL, not its title")
    func historyFillsURL() throws {
        #expect(SpotlightController.fieldText(for: try historyEntry(), typedQuery: "git") == "https://github.com")
    }

    @Test("the search row restores the typed query, not the engine URL")
    func searchRestoresQuery() throws {
        let row = try #require(HistoryFuzzyEntry.searchRow(query: "git", engine: engine))
        // Sanity: the row's own URL is the engine destination, which is
        // exactly what must not land in the field.
        #expect(row.url.contains("git"))
        #expect(row.url != "git")
        #expect(SpotlightController.fieldText(for: row, typedQuery: "git") == "git")
    }

    @Test("an empty typed query restores empty")
    func emptyQueryRestoresEmpty() throws {
        // Typed text is trimmed when stashed, so a cleared field restores
        // cleared rather than a stale query.
        let row = try #require(HistoryFuzzyEntry.searchRow(query: "git", engine: engine))
        #expect(SpotlightController.fieldText(for: row, typedQuery: "") == "")
    }
}
