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

/// Window-size form rules: parsing both fields and clamping the result.
/// Pure values, no card or window needed.
@MainActor
struct WindowSizeTests {
    @Test("plain pixel values parse")
    func parsesPlainValues() {
        let size = WindowSizeForm.parse(width: "1280", height: "800")
        #expect(size?.width == 1280)
        #expect(size?.height == 800)
    }

    @Test("surrounding whitespace and fractions parse")
    func parsesWhitespaceAndFractions() {
        let size = WindowSizeForm.parse(width: "  1280.5 ", height: "\t800\n")
        #expect(size?.width == 1280.5)
        #expect(size?.height == 800)
    }

    @Test("empty, textual, zero, and negative fields fail")
    func rejectsBadFields() {
        #expect(WindowSizeForm.parse(width: "", height: "800") == nil)
        #expect(WindowSizeForm.parse(width: "wide", height: "800") == nil)
        #expect(WindowSizeForm.parse(width: "1280", height: "tall") == nil)
        #expect(WindowSizeForm.parse(width: "0", height: "800") == nil)
        #expect(WindowSizeForm.parse(width: "-1280", height: "800") == nil)
        #expect(WindowSizeForm.parse(width: "1280", height: "-800") == nil)
        #expect(WindowSizeForm.parse(width: "NaN", height: "800") == nil)
        #expect(WindowSizeForm.parse(width: "inf", height: "800") == nil)
    }

    @Test("in-range sizes pass clamping through")
    func clampingPassesThrough() {
        let size = WindowSizeForm.clamped(NSSize(width: 1280, height: 800))
        #expect(size.width == 1280)
        #expect(size.height == 800)
    }

    @Test("tiny sizes clamp up to the chrome minimum")
    func clampingFloors() {
        let size = WindowSizeForm.clamped(NSSize(width: 10, height: 10))
        #expect(size.width == WindowSizeForm.minimumWidth)
        #expect(size.height == WindowSizeForm.minimumHeight)
    }

    @Test("absurd sizes clamp down to the maximum")
    func clampingCeilings() {
        let size = WindowSizeForm.clamped(NSSize(width: 99_999, height: 99_999))
        #expect(size.width == WindowSizeForm.maximumDimension)
        #expect(size.height == WindowSizeForm.maximumDimension)
    }
}
