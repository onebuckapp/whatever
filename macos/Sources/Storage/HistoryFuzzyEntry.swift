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

/// One fuzzy search hit: a history row plus where the query matched inside it.
///
/// The core scores a row as its title and URL joined and then splits the match
/// back onto the two fields, so a hit is one row however many of its fields took
/// part. `titlePositions` and `urlPositions` are byte offsets into their own field.
struct HistoryFuzzyEntry: Identifiable, Decodable, Hashable {
    let id: String
    let url: String
    let title: String
    let host: String
    let firstVisited: Date
    let lastVisited: Date
    let visitCount: Int
    /// openparser's length-normalised score, higher ranks first. Carried through
    /// rather than used for ordering here, because the core has already ordered
    /// the list; it is what a future title/URL blend would compare.
    let score: Double
    let titlePositions: [Int]
    let urlPositions: [Int]
    /// Whether the row's URL is bookmarked. The core never sends this —
    /// history has no notion of bookmarks — so decoding defaults it to
    /// false and the controller flags rows from the prewarmed cache.
    /// Bookmark-sourced rows are born flagged.
    var isBookmarked: Bool

    /// Identity of the synthetic search row. Constant across rebuilds, so typing
    /// another character replaces the row in place instead of dropping a
    /// highlight the user just arrowed onto. The core issues UUIDs, so no real
    /// history row can collide with this.
    static let searchRowID = "search"

    /// Whether this is the synthetic `Search for "…"` row rather than history.
    /// The dropdown treats it differently: choosing it leaves the typed text in
    /// the field instead of rewriting it with the destination.
    var isSearchRow: Bool { id == Self.searchRowID }

    /// The omnibox first row for `query`: `Search for "<query>"`, navigating
    /// through the address parser exactly as Enter on the typed text would,
    /// so URLs still go direct. Nil for blank queries and when no destination
    /// builds. The engine's name is the second line, so the row reads
    /// `Search for "cats" / Google` rather than flashing the search URL.
    static func searchRow(query: String, engine: ResolvedSearchEngine) -> HistoryFuzzyEntry? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let destination = AddressParser.url(from: trimmed, searchEngine: engine)
        else { return nil }
        return HistoryFuzzyEntry(
            id: Self.searchRowID,
            url: destination.absoluteString,
            title: "Search for \"\(trimmed)\"",
            host: engine.title,
            firstVisited: Date(),
            lastVisited: Date(),
            visitCount: 0,
            // The row is prepended explicitly, never sorted in: like the
            // recent-history rows, it carries no score.
            score: 0,
            titlePositions: [],
            urlPositions: []
        )
    }

    private init(
        id: String,
        url: String,
        title: String,
        host: String,
        firstVisited: Date,
        lastVisited: Date,
        visitCount: Int,
        score: Double,
        titlePositions: [Int],
        urlPositions: [Int],
        isBookmarked: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.host = host
        self.firstVisited = firstVisited
        self.lastVisited = lastVisited
        self.visitCount = visitCount
        self.score = score
        self.titlePositions = titlePositions
        self.urlPositions = urlPositions
        self.isBookmarked = isBookmarked
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, title, host, firstVisited, lastVisited, visitCount
        case score, titlePositions, urlPositions, isBookmarked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        // A row with no title is normal: the store records whatever the page had
        // at commit time, and some pages never set one.
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        host = (try? container.decode(String.self, forKey: .host)) ?? ""
        firstVisited = Date(timeIntervalSince1970: TimeInterval(try container.decode(Int64.self, forKey: .firstVisited)))
        lastVisited = Date(timeIntervalSince1970: TimeInterval(try container.decode(Int64.self, forKey: .lastVisited)))
        visitCount = (try? container.decode(Int.self, forKey: .visitCount)) ?? 1
        // Not optional-tolerant: a row without positions cannot be highlighted, and
        // quietly showing it unhighlighted would look like the matcher had found
        // nothing there. `decodeList` drops such a row instead.
        score = try container.decode(Double.self, forKey: .score)
        titlePositions = try container.decode([Int].self, forKey: .titlePositions)
        urlPositions = try container.decode([Int].self, forKey: .urlPositions)
        // Never sent by the core; see the property note.
        isBookmarked = (try? container.decode(Bool.self, forKey: .isBookmarked)) ?? false
    }

    /// Builds an unhighlighted entry from a plain history row.
    ///
    /// The recent-history list has no positions, because nothing was matched: it is
    /// what the dropdown shows for an empty field, where recency is the ranking.
    /// Both position lists are empty, so the rows render plainly.
    init(_ entry: HistoryEntry) {
        self.id = entry.id
        self.url = entry.url
        self.title = entry.title
        self.host = entry.host
        self.firstVisited = entry.firstVisited
        self.lastVisited = entry.lastVisited
        self.visitCount = entry.visitCount
        self.score = 0
        self.titlePositions = []
        self.urlPositions = []
        self.isBookmarked = false
    }

    /// Builds an entry from a bookmark hit.
    ///
    /// The matcher reports UTF-8 byte offsets, the same form the core uses,
    /// so highlighting is shared. `visitCount` is always 0: a bookmarked URL
    /// that also matched history is represented by its history row instead
    /// (see `SpotlightController.blend`), and history is the only record of
    /// visits — which is exactly why bookmarks survive a history clear while
    /// contributing no frequency of their own.
    init(bookmark node: BookmarkNode, score: Double, titlePositions: [Int], urlPositions: [Int]) {
        let url = node.url ?? ""
        self.init(
            id: node.id,
            url: url,
            title: node.title,
            host: URL(string: url)?.host?.lowercased() ?? "",
            firstVisited: Date(),
            lastVisited: Date(),
            visitCount: 0,
            score: score,
            titlePositions: titlePositions,
            urlPositions: urlPositions,
            isBookmarked: true
        )
    }

    /// Decodes a result set, dropping rows that are not usable objects.
    ///
    /// One malformed row should cost that row rather than the whole dropdown,
    /// which is what `HistoryEntry.decodeList` does for the settings list.
    static func decodeList(_ data: Data) -> [HistoryFuzzyEntry] {
        guard let rows = try? JSONDecoder().decode([FailableEntry].self, from: data) else {
            return []
        }
        return rows.compactMap(\.entry)
    }

    private struct FailableEntry: Decodable {
        let entry: HistoryFuzzyEntry?

        init(from decoder: Decoder) throws {
            entry = try? HistoryFuzzyEntry(from: decoder)
        }
    }

    /// Second line of a dropdown row: the full URL when the row has a title,
    /// so sibling pages under one host can be told apart. When the title is
    /// empty the first line already shows the URL, so the second line falls
    /// back to the host rather than repeating it. The synthetic search row
    /// keeps the engine's name: its URL is the search destination, and the
    /// row reads `Search for "cats" / Google` rather than flashing that URL.
    var subtitle: String {
        if isSearchRow { return host }
        return title.isEmpty ? (host.isEmpty ? url : host) : url
    }

    /// Highlight for `subtitle`: the URL match positions whenever the
    /// subtitle is the URL. A host subtitle has no positions of its own, and
    /// borrowing the URL's offsets against a shorter string would paint the
    /// wrong characters. The search row carries no positions at all.
    var subtitleHighlight: [NSRange] {
        isSearchRow ? [] : (!title.isEmpty || host.isEmpty ? urlHighlight : [])
    }

    /// Where the match landed in the title, as character ranges.
    ///
    /// The core reports **byte** offsets and `NSAttributedString` needs character
    /// ranges, so these are converted rather than used directly. Titles with any
    /// non-ASCII text in them would otherwise highlight from the wrong character
    /// onward: `"Café Zürich Zebra"` is 17 characters but 19 bytes, so byte 15 is
    /// character 13.
    var titleHighlight: [NSRange] {
        Self.characterRanges(forByteOffsets: titlePositions, in: title)
    }

    var urlHighlight: [NSRange] {
        Self.characterRanges(forByteOffsets: urlPositions, in: url)
    }

    /// Turns UTF-8 byte offsets into character ranges over `text`.
    ///
    /// Walks the bytes once and records where each character begins, so a byte
    /// offset can be answered with the character it falls in. An offset landing
    /// mid-character is dropped rather than guessed at, which is what keeps a
    /// highlight safe when the core's matcher cannot be trusted: the matcher walks
    /// bytes and folds case only for ASCII, so a query character outside ASCII is
    /// matched byte by byte. `ü` is `C3 BC`, and `"Café Zürich"` has an `é` that
    /// also begins with `C3`, so a query for `ü` can be satisfied with the `é`
    /// supplying the first byte and the `ü` the second. Those offsets do not
    /// describe the characters the user typed; dropping them means the row shows
    /// unhighlighted rather than wrongly highlighted.
    static func characterRanges(forByteOffsets offsets: [Int], in text: String) -> [NSRange] {
        guard !offsets.isEmpty else { return [] }
        let bytes = Array(text.utf8)
        // Byte offset at which each character begins, so the walk below can answer
        // "which character is this byte in?" without a second pass.
        var starts: [Int] = []
        starts.reserveCapacity(bytes.count)
        var offset = 0
        while offset < bytes.count {
            starts.append(offset)
            let lead = bytes[offset]
            // A UTF-8 lead byte carries its own length in its top bits: 110xxxxx is
            // two bytes, 1110xxxx three, 11110xxx four.
            let width: Int
            switch lead {
            case 0xC0...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF7: width = 4
            default: width = 1
            }
            offset += width
        }

        var ranges: [NSRange] = []
        ranges.reserveCapacity(offsets.count)
        for byteOffset in offsets.sorted() {
            guard byteOffset >= 0, byteOffset < bytes.count else { continue }
            // Only an offset that actually starts a character can become a range.
            // For an ASCII query every reported offset is a character start, so this
            // only ever drops something; see the note above.
            guard let character = starts.firstIndex(of: byteOffset) else { continue }
            ranges.append(NSRange(location: character, length: 1))
        }
        return merge(ranges)
    }

    /// Collapses runs of adjacent single-character ranges into one range.
    ///
    /// The matcher reports one offset per matched byte, so "GitHub" matches as
    /// five separate single-character highlights. Painting five runs would look
    /// like the word had gaps in it.
    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last,
               last.location + last.length == range.location {
                merged[merged.count - 1] = NSRange(location: last.location, length: last.length + range.length)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}