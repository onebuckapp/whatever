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
