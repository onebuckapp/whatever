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

/// The dropdown row's second line: the full URL for history rows, so sibling
/// pages under one host can be told apart — never just the host.
struct SpotlightSubtitleTests {
    private func entry(
        title: String,
        url: String,
        host: String,
        urlPositions: [Int] = []
    ) -> HistoryFuzzyEntry {
        let json = """
        [{"id":"1","url":"\(url)","title":"\(title)","host":"\(host)",\
        "firstVisited":1700000000,"lastVisited":1700000100,"visitCount":3,\
        "score":1.5,"titlePositions":[],"urlPositions":[\(urlPositions.map(String.init).joined(separator: ","))]}]
        """
        let entries = HistoryFuzzyEntry.decodeList(json.data(using: .utf8)!)
        #expect(entries.count == 1)
        return entries[0]
    }

    @Test("titled row subtitles the full url, not the host")
    func fullURL() {
        let row = entry(
            title: "Actions",
            url: "https://github.com/features/actions",
            host: "github.com",
            urlPositions: [8, 9, 10, 11, 12, 13]
        )
        #expect(row.subtitle == "https://github.com/features/actions")
        #expect(row.subtitleHighlight.count == 1)
    }

    @Test("untitled row keeps the host subtitle, since the url is the title")
    func untitledKeepsHost() {
        let row = entry(title: "", url: "https://github.com", host: "github.com")
        #expect(row.subtitle == "github.com")
        #expect(row.subtitleHighlight.isEmpty)
    }

    @Test("search row keeps the engine name, not the search url")
    func searchRowKeepsEngine() {
        let engine = PredefinedSearchEngine.duckDuckGo.resolved
        let row = HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)
        #expect(row?.subtitle == engine.title)
        #expect(row?.subtitleHighlight.isEmpty == true)
    }
}
