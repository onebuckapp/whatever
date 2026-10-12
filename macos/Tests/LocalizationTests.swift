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

/// Shell-side translation cache: key derivation, lookup fallback, batch
/// shapes. The core owns actual translation (pinned in `test_locale.nim`);
/// here only the concatenation the cache shares with it, and the JSON it
/// exchanges with the service.
@MainActor
struct LocalizationTests {
    private func table() -> LocaleTable {
        LocaleTable(
            lang: "ro",
            strings: [
                "Record visited pages": "Înregistrează paginile vizitate",
                "Settings.General\u{04}History": "Istoric",
            ]
        )
    }

    @Test("the cache key mirrors the core's context join")
    func keyDerivation() {
        #expect(Localization.key(msgid: "History", ctx: "") == "History")
        #expect(Localization.key(msgid: "History", ctx: "Settings.General") == "Settings.General\u{04}History")
    }

    @Test("a cached entry reads back, plain and with context")
    func cachedLookup() {
        let localization = Localization()
        localization.load(table: table())
        #expect(localization.lookup(msgid: "Record visited pages", ctx: "") == "Înregistrează paginile vizitate")
        #expect(localization.lookup(msgid: "History", ctx: "Settings.General") == "Istoric")
    }

    @Test("a missing entry reads back its English msgid")
    func missingFallsBack() {
        let localization = Localization()
        localization.load(table: table())
        #expect(localization.lookup(msgid: "No such string", ctx: "Settings.General") == "No such string")
        #expect(localization.lookup(msgid: "History", ctx: "Other.Screen") == "History")
    }

    @Test("loading a table reports its language and ticks the revision")
    func loadReports() {
        let localization = Localization()
        let before = localization.revision
        localization.load(table: table())
        #expect(localization.lang == "ro")
        #expect(localization.revision == before + 1)
    }

    @Test("a language tag resolves to its native name")
    func nativeDisplayName() {
        #expect(Localization.displayName(for: "ro") == "Română")
    }

    @Test("an unknown tag displays as itself rather than blank")
    func unknownTagEcho() {
        #expect(Localization.displayName(for: "xx") == "xx")
    }

    @Test("batch items encode the core's document shape")
    func batchEncoding() throws {
        let items = [
            LocaleItem("Record visited pages", ctx: "Settings.General"),
            LocaleItem("one file", plural: "{n} files", n: 20, args: ["n": "20"]),
        ]
        let document = try JSONEncoder().encode(LocaleBatch(items: items))
        let decoded = try JSONDecoder().decode(LocaleBatch.self, from: document)
        #expect(decoded.items.count == 2)
        #expect(decoded.items[0].msgid == "Record visited pages")
        #expect(decoded.items[0].msgctxt == "Settings.General")
        #expect(decoded.items[1].n == 20)
        #expect(decoded.items[1].args == ["n": "20"])
    }

    @Test("batch results decode to texts in order")
    func batchDecoding() throws {
        let data = Data(#"{"texts":["Înregistrează paginile vizitate","20 de fișiere"]}"#.utf8)
        #expect(try JSONDecoder().decode(LocaleBatchResult.self, from: data).texts == [
            "Înregistrează paginile vizitate", "20 de fișiere",
        ])
    }

    @Test("a batch item fills {n} from its count unless the caller set it")
    func batchItemFillsCount() {
        #expect(LocaleItem("one visit", plural: "{n} visits", n: 5).args == ["n": "5"])
        #expect(LocaleItem("{n} cookie", ctx: "SiteInfo", plural: "{n} cookies", n: 1).args == ["n": "1"])
        #expect(LocaleItem("one file", plural: "{n} files", n: 20, args: ["n": "20"]).args == ["n": "20"])
        #expect(LocaleItem("one file", plural: "{n} files", n: 20, args: ["n": "many"]).args == ["n": "many"])
        #expect(LocaleItem("Record visited pages", ctx: "Settings.General").args == nil)
    }

    @Test("the cached table decodes the core's document shape")
    func tableDecoding() throws {
        let data = Data(#"{"lang":"ro","strings":{"a":"b"}}"#.utf8)
        let decoded = try JSONDecoder().decode(LocaleTable.self, from: data)
        #expect(decoded.lang == "ro")
        #expect(decoded.strings == ["a": "b"])
    }
}
