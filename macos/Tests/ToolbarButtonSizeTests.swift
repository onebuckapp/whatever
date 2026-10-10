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

/// Toolbar buttons share one frame: the strip's stacks size the alignment
/// axis from `fittingSize`, and the cell behind the button derives that
/// from the glyph — so large system glyphs used to come out 26–29pt tall
/// while the smaller bundled vectors held 22, and every button hovered a
/// different fill. Pure values, no strip needed.
@MainActor
struct ToolbarButtonSizeTests {
    @Test("every button fits 32x24 whatever its glyph")
    func fittingSizeUniform() {
        let plain = BrowserToolbarButton()
        #expect(plain.fittingSize == NSSize(width: 32, height: 24))
        let glyphs: [NSImage?] = [
            NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium)),
            NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium)),
            BrowserToolbarButton.bundledGlyphImage(named: "RSS", inkRatio: 0.75),
            BrowserToolbarButton.bundledGlyphImage(named: "ShieldCheck", inkRatio: 0.88),
            BrowserToolbarButton.bundledGlyphImage(named: "AccessPoint", inkRatio: 0.556),
        ]
        for glyph in glyphs {
            let button = BrowserToolbarButton()
            button.image = glyph
            #expect(button.fittingSize == NSSize(width: 32, height: 24))
        }
    }
}
