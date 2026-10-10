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

/// In-process subsequence matching over the prewarmed bookmark cache.
///
/// History matching lives in the core (`historyFuzzySearch`, openparser
/// scorer over XPC); bookmarks are matched here instead, against
/// `BookmarkStore.shared.nodes`, so no store round trip sits on the
/// keystroke path. The semantics mirror the core's deliberately: every query
/// character must appear in order, case-insensitively, in the title or the
/// URL — but the score only ever orders bookmarks against each other and
/// breaks ties in the blended list (visits and URL length rank first), so it
/// is its own small scale rather than a port of openparser's.
///
/// Only links match, never folders: a folder is not a destination. Matches
/// spanning the title into the URL are not attempted — the core keeps that
/// case for history via its joined scoring, and a typed query reaching
/// across a bookmark's title boundary is vanishingly rare.
enum BookmarkMatcher {
    /// One bookmark hit: the node plus where the query landed, as UTF-8
    /// byte offsets into each field — the same form the core reports, so
    /// `HistoryFuzzyEntry` highlights them identically.
    struct Hit {
        let node: BookmarkNode
        let score: Double
        let titlePositions: [Int]
        let urlPositions: [Int]
    }

    /// Queries shorter than two characters match nothing: one character is a
    /// prefix, not a search, and the bar answers those without querying.
    static let minimumQueryLength = 2

    static func hits(query: String, nodes: [BookmarkNode]) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumQueryLength else { return [] }
        var hits: [Hit] = []
        for node in nodes {
            guard node.kind == .link, let url = node.url, !url.isEmpty else { continue }
            if let hit = match(node: node, query: trimmed, url: url) {
                hits.append(hit)
            }
        }
        return hits
    }

    private static func match(node: BookmarkNode, query: String, url: String) -> Hit? {
        let titleScore = score(query: query, in: node.title)
        let urlScore = score(query: query, in: url)
        switch (titleScore, urlScore) {
        case let (title?, url?) where title.score >= url.score:
            return Hit(node: node, score: title.score,
                       titlePositions: byteOffsets(for: title.positions, in: node.title),
                       urlPositions: [])
        case let (_, urlScore?):
            return Hit(node: node, score: urlScore.score,
                       titlePositions: [],
                       urlPositions: byteOffsets(for: urlScore.positions, in: url))
        case let (titleScore?, nil):
            return Hit(node: node, score: titleScore.score,
                       titlePositions: byteOffsets(for: titleScore.positions, in: node.title),
                       urlPositions: [])
        default:
            return nil
        }
    }

    private struct FieldScore {
        /// Character indices of the greedy leftmost match, in order.
        let positions: [Int]
        let score: Double
    }

    /// Greedy leftmost subsequence match with a small run/start bonus,
    /// length-normalised like the core's scores: a tight match on a short
    /// field outscores a scattered one on a long field. Nil when any query
    /// character is missing.
    private static func score(query: String, in field: String) -> FieldScore? {
        let needle = Array(query.lowercased())
        let haystack = Array(field.lowercased())
        guard !needle.isEmpty, !haystack.isEmpty else { return nil }
        var positions: [Int] = []
        positions.reserveCapacity(needle.count)
        var from = 0
        for character in needle {
            guard let found = haystack[from...].firstIndex(of: character) else {
                return nil
            }
            positions.append(found)
            from = found + 1
        }
        var raw = 0.0
        for (index, position) in positions.enumerated() {
            raw += 1
            if index > 0, position == positions[index - 1] + 1 {
                raw += 1.5
            }
            if position == 0 || !(haystack[position - 1].isLetter || haystack[position - 1].isNumber) {
                raw += 1
            }
        }
        let span = positions.last! - positions.first! + 1
        raw -= 0.5 * Double(span - positions.count)
        return FieldScore(positions: positions, score: raw / Double(haystack.count))
    }

    /// Character indices into UTF-8 byte offsets. URLs are near-always
    /// ASCII, where the two coincide; titles may not be, and the entry's
    /// highlight conversion expects bytes.
    private static func byteOffsets(for characters: [Int], in text: String) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(text.count)
        var offset = 0
        for character in text {
            starts.append(offset)
            offset += character.utf8.count
        }
        return characters.compactMap { $0 < starts.count ? starts[$0] : nil }
    }
}
