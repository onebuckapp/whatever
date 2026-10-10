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

/// Bundled toolbar vectors: boxed by ink height so they paint the same
/// size as the system glyphs, on independent instances so one sizing can
/// never move another use of the asset.
@MainActor
struct ToolbarGlyphTests {
    @Test("bundled glyphs box to whole-point sizes near the system glyphs")
    func boxesByInk() {
        // 14.5pt of ink over each asset's measured ratio, rounded: RSS and
        // the fingerprint at 19pt, both shield states at 17pt.
        let rss = BrowserToolbarButton.bundledGlyphImage(named: "RSS", inkRatio: 0.75)
        #expect(rss?.size == NSSize(width: 19, height: 19))
        let check = BrowserToolbarButton.bundledGlyphImage(named: "ShieldCheck", inkRatio: 0.85)
        #expect(check?.size == NSSize(width: 17, height: 17))
        let cross = BrowserToolbarButton.bundledGlyphImage(named: "ShieldX", inkRatio: 0.85)
        #expect(cross?.size == NSSize(width: 17, height: 17))
        let fingerprint = BrowserToolbarButton.bundledGlyphImage(
            named: "TablerAsterisk",
            inkRatio: 0.833
        )
        #expect(fingerprint?.size == NSSize(width: 17, height: 17))
        // Trailing buttons and the page star, same 14.5pt ink target: the
        // bookmark and settings vectors at 17pt, downloads at 19pt, both
        // star states sharing one box so the toggle never moves the glyph.
        let panelBookmark = BrowserToolbarButton.bundledGlyphImage(named: "TablerBookmark", inkRatio: 0.833)
        #expect(panelBookmark?.size == NSSize(width: 17, height: 17))
        let downloads = BrowserToolbarButton.bundledGlyphImage(named: "TablerDownloads", inkRatio: 0.75)
        #expect(downloads?.size == NSSize(width: 19, height: 19))
        let settings = BrowserToolbarButton.bundledGlyphImage(named: "TablerSettings", inkRatio: 0.833)
        #expect(settings?.size == NSSize(width: 17, height: 17))
        let star = BrowserToolbarButton.bundledGlyphImage(named: "TablerStar", inkRatio: 0.875)
        #expect(star?.size == NSSize(width: 17, height: 17))
        let starFilled = BrowserToolbarButton.bundledGlyphImage(named: "TablerStarFilled", inkRatio: 0.875)
        #expect(starFilled?.size == NSSize(width: 17, height: 17))
        // Leading cluster, same band: the reload arrow at 19pt, both
        // chevrons sharing one box (narrow glyphs, height-matched).
        let reload = BrowserToolbarButton.bundledGlyphImage(named: "TablerReload", inkRatio: 0.75)
        #expect(reload?.size == NSSize(width: 19, height: 19))
        let chevronLeft = BrowserToolbarButton.bundledGlyphImage(named: "TablerChevronLeft", inkRatio: 0.725)
        #expect(chevronLeft?.size == NSSize(width: 20, height: 20))
        let chevronRight = BrowserToolbarButton.bundledGlyphImage(named: "TablerChevronRight", inkRatio: 0.725)
        #expect(chevronRight?.size == NSSize(width: 20, height: 20))
        for image in [rss, check, cross, fingerprint, panelBookmark, downloads, settings, star, starFilled, reload, chevronLeft, chevronRight] {
            #expect(image?.isTemplate == true)
        }
    }

    @Test("unknown assets and ratios fail instead of guessing")
    func rejectsBadInput() {
        #expect(BrowserToolbarButton.bundledGlyphImage(named: "NoSuchGlyph", inkRatio: 0.75) == nil)
        #expect(BrowserToolbarButton.bundledGlyphImage(named: "RSS", inkRatio: 0) == nil)
        #expect(BrowserToolbarButton.bundledGlyphImage(named: "RSS", inkRatio: -1) == nil)
    }

    @Test("each call sizes its own copy: the asset cache is shared")
    func copiesBeforeSizing() {
        let first = BrowserToolbarButton.bundledGlyphImage(named: "RSS", inkRatio: 0.75)
        #expect(first?.size == NSSize(width: 19, height: 19))
        // A second sizing of the same asset must leave the first alone:
        // `NSImage(named:)` returns one shared instance.
        _ = BrowserToolbarButton.bundledGlyphImage(named: "RSS", inkRatio: 0.5)
        #expect(first?.size == NSSize(width: 19, height: 19))
    }
}
