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

/// Tab shape: the radius rule per shape and the strip's vertical metrics.
/// Pure values, no shared store needed.
@MainActor
struct TabShapeTests {
    @Test("attached caps the slider at half the cell height")
    func attachedCaps() {
        #expect(TabShape.attached.cornerRadius(setting: 8, height: 32) == 8)
        #expect(TabShape.attached.cornerRadius(setting: 20, height: 32) == 16)
        #expect(TabShape.attached.cornerRadius(setting: -3, height: 32) == 0)
        #expect(TabShape.attached.cornerRadius(setting: 8, height: 0) == 8)
    }

    @Test("pills ignore the slider and take the full stadium radius")
    func pillsAreFull() {
        #expect(TabShape.pills.cornerRadius(setting: 0, height: 28) == 14)
        #expect(TabShape.pills.cornerRadius(setting: 8, height: 28) == 14)
        #expect(TabShape.pills.cornerRadius(setting: 20, height: 28) == 14)
        #expect(TabShape.pills.cornerRadius(setting: 8, height: 0) == 0)
    }

    @Test("only pills round the bottom corners")
    func bottomRounding() {
        #expect(TabShape.pills.roundsBottomCorners == true)
        #expect(TabShape.attached.roundsBottomCorners == false)
    }

    @Test("pills name all four corners, attached only the top pair")
    func layerRounding() {
        let pills = TabShape.pills.layerRounding
        #expect(pills.contains(.layerMinXMinYCorner))
        #expect(pills.contains(.layerMaxXMinYCorner))
        #expect(pills.contains(.layerMinXMaxYCorner))
        #expect(pills.contains(.layerMaxXMaxYCorner))
        #expect(TabShape.attached.layerRounding == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
    }

    @Test("pills round the page top too, attached leaves it square")
    func pageRounding() {
        let pills = TabShape.pills.pageRounding
        #expect(pills.contains(.layerMinXMinYCorner))
        #expect(pills.contains(.layerMaxXMinYCorner))
        #expect(pills.contains(.layerMinXMaxYCorner))
        #expect(pills.contains(.layerMaxXMaxYCorner))
        #expect(TabShape.attached.pageRounding == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    @Test("attached cells sit flush, pills float with a gap above the page")
    func verticalMetrics() {
        let attached = TabBarView.cellVerticalMetrics(barHeight: 36, shape: .attached)
        #expect(attached.y == 4)
        #expect(attached.height == 32)
        let pills = TabBarView.cellVerticalMetrics(barHeight: 36, shape: .pills)
        #expect(pills.y == 4)
        #expect(pills.height == 28)
        // The gap: the pill's bottom edge stops short of the bar.
        #expect(pills.y + pills.height == 32)
    }

    @Test("the shape picker titles every case")
    func titles() {
        #expect(TabShape.attached.title == "Attached")
        #expect(TabShape.pills.title == "Pills")
        #expect(TabShape.allCases.count == 2)
    }
}
