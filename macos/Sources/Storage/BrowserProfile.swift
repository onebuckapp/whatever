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

/// One browser profile: an id the core owns plus display metadata.
///
/// The id is permanent — renames change the name only — and doubles as the
/// store directory name, which is why the core restricts its charset. Decode
/// is tolerant the way history rows are: a malformed entry costs that entry,
/// not the registry.
struct BrowserProfile: Codable, Equatable, Identifiable, Sendable {
    /// The core's id for the built-in profile. Swift needs it in one place:
    /// the default profile keeps WebKit's default data store, so its
    /// cookies predate profiles and stay where they are.
    static let defaultID = "default"

    var id: String
    var name: String
    var createdAt: Date
    var lastUsedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, lastUsedAt
    }

    init(id: String, name: String, createdAt: Date, lastUsedAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // A blank name reads as the id: the core refuses blank names going
        // forward, but an old or hand-edited registry should still open.
        let storedName = (try? container.decode(String.self, forKey: .name)) ?? ""
        name = storedName.isEmpty ? id : storedName
        // The core writes Unix seconds; a missing stamp reads as the epoch
        // rather than failing the whole registry.
        createdAt = Date(
            timeIntervalSince1970: TimeInterval(
                (try? container.decode(Int64.self, forKey: .createdAt)) ?? 0))
        lastUsedAt = Date(
            timeIntervalSince1970: TimeInterval(
                (try? container.decode(Int64.self, forKey: .lastUsedAt)) ?? 0))
    }

    /// Decodes the registry document `{"profiles": [...]}`. Nil when the
    /// payload is not a registry at all; individual bad entries are dropped
    /// by the entry decoder above, not here.
    static func decodeRegistry(_ data: Data) -> [BrowserProfile]? {
        guard let document = try? JSONDecoder().decode(Registry.self, from: data) else {
            return nil
        }
        return document.profiles
    }

    private struct Registry: Decodable {
        var profiles: [BrowserProfile]
    }
}
