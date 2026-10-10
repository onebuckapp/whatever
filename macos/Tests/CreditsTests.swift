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

/// The Credits window: full attribution list, single instance, and a
/// cover-bleed geometry for the background art.
@MainActor
struct CreditsTests {
    @Test("every section lists at least one entry, links are valid urls")
    func contentComplete() {
        #expect(!CreditsContent.sections.isEmpty)
        for section in CreditsContent.sections {
            #expect(!section.title.isEmpty)
            #expect(!section.entries.isEmpty)
            for entry in section.entries {
                #expect(!entry.name.isEmpty)
                #expect(!entry.detail.isEmpty)
            }
        }
        let linked = CreditsContent.sections.flatMap(\.entries).compactMap(\.url)
        #expect(!linked.isEmpty)
        for url in linked {
            #expect(url.scheme == "https")
        }
    }

    @Test("titles pair names with licenses, links stay raw urls")
    func titleAndLinkFormat() {
        let entries = Dictionary(
            CreditsContent.sections.flatMap(\.entries).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(entries["Tabler Icons"]?.titleLine == "Tabler Icons | MIT-licensed")
        #expect(entries["Tabler Icons"]?.url?.absoluteString == "https://tabler.io")
        #expect(entries["Mijick Popups"]?.titleLine == "Mijick Popups | Apache-2.0 license")
        #expect(entries["boogie"]?.titleLine == "boogie | MIT-licensed")
        #expect(entries["boogie"]?.detail == "A suite of WAL-based embedded data stores")
        #expect(entries["boogie"]?.url?.absoluteString == "https://github.com/openpeeps/boogie")
        #expect(entries["openparser"]?.titleLine == "openparser | MIT-licensed")
        #expect(entries["openparser"]?.url?.absoluteString == "https://github.com/openpeeps/openparser")
        #expect(entries["nimcypher"]?.titleLine == "nimcypher | BSD-2-Clause")
        #expect(entries["nimcypher"]?.detail == "Pure-Nim cryptographic library")
        #expect(entries["nimcypher"]?.url?.absoluteString == "https://github.com/nimbase/nimcypher")
        #expect(entries["blackpaper"]?.titleLine == "blackpaper | MIT-licensed")
        #expect(entries["blackpaper"]?.url?.absoluteString == "https://github.com/openpeeps/blackpaper")
        #expect(entries["Nim"]?.titleLine == "Nim")
        #expect(entries["Nim"]?.detail == "A statically typed compiled systems programming language")
        #expect(entries["Nim"]?.url?.absoluteString == "https://nim-lang.org")
        #expect(entries["Swift"]?.url?.absoluteString == "https://swift.org")
    }

    @Test("written-in comes right after made-by")
    func sectionOrder() {
        let titles = CreditsContent.sections.map(\.title)
        #expect(titles.firstIndex(of: "Written in") == (titles.firstIndex(of: "Made by") ?? -1) + 1)
    }

    @Test("cover rect fills the bounds and centers the image")
    func coverGeometry() {
        // Wide image in a square window: full height, overflowing sides.
        let wide = CreditsBackgroundView.imageDrawRect(
            for: NSSize(width: 1600, height: 900),
            in: NSRect(x: 0, y: 0, width: 720, height: 520)
        )
        #expect(abs(wide.height - 520) < 0.5)
        #expect(wide.width > 720)
        #expect(abs(wide.midX - 360) < 0.5)
        // Tall image: full width, overflowing top and bottom.
        let tall = CreditsBackgroundView.imageDrawRect(
            for: NSSize(width: 900, height: 1600),
            in: NSRect(x: 0, y: 0, width: 720, height: 520)
        )
        #expect(abs(tall.width - 720) < 0.5)
        #expect(tall.height > 520)
        #expect(abs(tall.midY - 260) < 0.5)
        // Degenerate inputs never divide by zero.
        #expect(CreditsBackgroundView.imageDrawRect(
            for: .zero, in: NSRect(x: 0, y: 0, width: 720, height: 520)
        ) == NSRect(x: 0, y: 0, width: 720, height: 520))
    }

    @Test("reopening focuses the same window")
    func singleInstance() {
        let controller = CreditsWindowController()
        controller.show()
        let first = controller.windowForTesting
        #expect(first != nil)
        #expect(first?.title == "Credits")
        controller.show()
        #expect(controller.windowForTesting === first)
        first?.close()
        #expect(controller.windowForTesting == nil)
    }
}
