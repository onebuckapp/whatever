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
import WebKit
@testable import Whatever
import Testing

/// Profile registry decoding. The service round trip is covered by the Nim
/// suite; here only the app-side shape is pinned, with no XPC.
@MainActor
struct ProfileRegistryTests {
    @Test("a registry document decodes to profiles")
    func decodes() throws {
        let data = Data(
            """
            {"profiles": [
              {"id": "default", "name": "Default", "createdAt": 1700000000, "lastUsedAt": 1800000000},
              {"id": "work", "name": "Work", "createdAt": 1700000100, "lastUsedAt": 1700000200}
            ]}
            """.utf8
        )
        let profiles = try #require(BrowserProfile.decodeRegistry(data))
        #expect(profiles.count == 2)
        #expect(profiles[0].id == "default")
        #expect(profiles[0].name == "Default")
        #expect(profiles[0].createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(profiles[0].lastUsedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(profiles[1].id == "work")
    }

    @Test("garbage is nil, not a crash")
    func rejectsGarbage() {
        #expect(BrowserProfile.decodeRegistry(Data("[]".utf8)) == nil)
        #expect(BrowserProfile.decodeRegistry(Data("".utf8)) == nil)
        #expect(BrowserProfile.decodeRegistry(Data("{}".utf8)) == nil)
    }

    @Test("a sparse entry still decodes")
    func toleratesSparseEntries() throws {
        let data = Data(
            """
            {"profiles": [{"id": "thin", "name": "", "createdAt": 0, "lastUsedAt": 0}]}
            """.utf8
        )
        let profiles = try #require(BrowserProfile.decodeRegistry(data))
        #expect(profiles.count == 1)
        // A blank name falls back to the id rather than dropping the entry.
        #expect(profiles[0].name == "thin")
    }

    @Test("cookie jar ids are stable and partitioned")
    func dataStoreIDs() {
        let first = ProfileContext.dataStoreID(for: "work")
        let second = ProfileContext.dataStoreID(for: "work")
        #expect(first == second)
        #expect(first != ProfileContext.dataStoreID(for: "personal"))
    }

    @Test("the default profile keeps the default data store")
    func defaultCookieJar() {
        // Identity, not equality: the default profile must share WebKit's
        // singleton store (and its pre-profiles cookies), not a partition.
        #expect(ProfileContext.cookieJar(for: "default") === WKWebsiteDataStore.default())
    }
}
