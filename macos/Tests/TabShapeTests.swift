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

    @Test("below the page attached cells mirror: square top, round bottom")
    func cellCornersMirror() {
        #expect(TabShape.attached.cellCorners(tabsAtBottom: false) == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        #expect(TabShape.attached.cellCorners(tabsAtBottom: true) == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
        let pills = TabShape.pills.cellCorners(tabsAtBottom: true)
        #expect(pills.contains(.layerMinXMinYCorner))
        #expect(pills.contains(.layerMaxXMinYCorner))
        #expect(pills.contains(.layerMinXMaxYCorner))
        #expect(pills.contains(.layerMaxXMaxYCorner))
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

    @Test("below the page attached pages meet the bar squarely at the bottom")
    func pageCornersMirror() {
        #expect(TabShape.attached.pageCorners(tabsAtBottom: false) == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
        #expect(TabShape.attached.pageCorners(tabsAtBottom: true) == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        let pills = TabShape.pills.pageCorners(tabsAtBottom: true)
        #expect(pills.contains(.layerMinXMinYCorner))
        #expect(pills.contains(.layerMaxXMinYCorner))
        #expect(pills.contains(.layerMinXMaxYCorner))
        #expect(pills.contains(.layerMaxXMaxYCorner))
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

    @Test("below the page attached cells sit flush to the strip's top edge")
    func verticalMetricsMirrored() {
        let attached = TabBarView.cellVerticalMetrics(barHeight: 36, shape: .attached, tabsAtBottom: true)
        #expect(attached.y == 0)
        #expect(attached.height == 32)
        // Same breathing room, moved underneath the band.
        #expect(attached.y + attached.height == 32)
        let pills = TabBarView.cellVerticalMetrics(barHeight: 36, shape: .pills, tabsAtBottom: true)
        #expect(pills.y == 4)
        #expect(pills.height == 28)
    }

    @Test("the pills lift matches the pill band's top inset below the page")
    func pillsLiftMatchesBand() {
        let metrics = TabBarView.cellVerticalMetrics(
            barHeight: BrowserWindowContentViewController.tabBarHeight,
            shape: .pills,
            tabsAtBottom: true
        )
        #expect(BrowserWindowContentViewController.pillsLift == metrics.y)
        #expect(BrowserWindowContentViewController.pillsLift == 4)
    }

    @Test("the + button centers on the cell band in both shapes")
    func newTabButtonAlignment() {
        let buttonH = BrowserToolbarButton.outerHeight
        let attachedY = TabBarContainerView.newTabButtonY(barHeight: 36, shape: .attached)
        // No nudge either way: the button sits on the band midpoint.
        #expect(attachedY == (32 - buttonH) / 2)
        let pillsY = TabBarContainerView.newTabButtonY(barHeight: 36, shape: .pills)
        #expect(pillsY == 4 + (28 - buttonH) / 2)
        #expect(attachedY + buttonH / 2 == 16)
        #expect(pillsY + buttonH / 2 == 18)
    }

    @Test("below the page the + button mirrors onto the lowered band")
    func newTabButtonAlignmentMirrored() {
        let buttonH = BrowserToolbarButton.outerHeight
        let attachedY = TabBarContainerView.newTabButtonY(barHeight: 36, shape: .attached, tabsAtBottom: true)
        #expect(attachedY == 4 + (32 - buttonH) / 2)
        // Mirrored midpoint: 20 instead of 16.
        #expect(attachedY + buttonH / 2 == 20)
        // Pills are symmetric: same answer either way.
        #expect(
            TabBarContainerView.newTabButtonY(barHeight: 36, shape: .pills, tabsAtBottom: true)
                == TabBarContainerView.newTabButtonY(barHeight: 36, shape: .pills)
        )
    }

    @Test("the position pickers title every case")
    func positionTitles() {
        // Untranslated in tests, so titles read back their msgids.
        #expect(TabPosition.top.title == "Top")
        #expect(TabPosition.bottom.title == "Bottom")
        #expect(TabPosition.allCases.count == 2)
        #expect(AppSettings.CrawlPosition.bottom.title == "Bottom")
        #expect(AppSettings.CrawlPosition.top.title == "Top")
        #expect(AppSettings.CrawlPosition.allCases.count == 2)
    }

    @Test("the shape picker titles every case")
    func titles() {
        #expect(TabShape.attached.title == "Attached")
        #expect(TabShape.pills.title == "Pills")
        #expect(TabShape.allCases.count == 2)
    }
}
