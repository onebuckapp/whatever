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

/// The long-press navigation menus: which entries the back and forward
/// buttons list, and in what order. Drives the ordering helper directly:
/// it has no panel and no tab, so the rule is pinned without clicking
/// anything.
struct HistoryMenuTests {
    private let urls = [
        URL(string: "https://a.example")!,
        URL(string: "https://b.example")!,
        URL(string: "https://c.example")!,
    ]

    @Test("back lists older entries nearest-first")
    func backNearestFirst() {
        let entries = BrowserToolbarController.historyEntries(
            urls: urls, index: 2, direction: .back)
        #expect(entries.map(\.index) == [1, 0])
        #expect(entries.map(\.url.absoluteString) == [
            "https://b.example", "https://a.example",
        ])
    }

    @Test("forward lists newer entries in order")
    func forwardInOrder() {
        let entries = BrowserToolbarController.historyEntries(
            urls: urls, index: 0, direction: .forward)
        #expect(entries.map(\.index) == [1, 2])
        #expect(entries.map(\.url.absoluteString) == [
            "https://b.example", "https://c.example",
        ])
    }

    @Test("the current page is never listed")
    func currentNeverListed() {
        let back = BrowserToolbarController.historyEntries(
            urls: urls, index: 1, direction: .back)
        #expect(back.map(\.index) == [0])
        let forward = BrowserToolbarController.historyEntries(
            urls: urls, index: 1, direction: .forward)
        #expect(forward.map(\.index) == [2])
    }

    @Test("dead ends and bad positions list nothing")
    func deadEndsAreEmpty() {
        #expect(BrowserToolbarController.historyEntries(
            urls: urls, index: 0, direction: .back).isEmpty)
        #expect(BrowserToolbarController.historyEntries(
            urls: urls, index: 2, direction: .forward).isEmpty)
        #expect(BrowserToolbarController.historyEntries(
            urls: urls, index: 7, direction: .back).isEmpty)
        #expect(BrowserToolbarController.historyEntries(
            urls: [], index: 0, direction: .forward).isEmpty)
    }

    @Test("titles map by exact and normalized address")
    func titleMapMerges() {
        let payload = """
        [
          {"id":"1","url":"https://a.example/","title":"A Page","host":"a.example","firstVisited":1700000000,"lastVisited":1700000000,"visitCount":3},
          {"id":"2","url":"https://b.example/x","title":"","host":"b.example","firstVisited":1700000000,"lastVisited":1700000000,"visitCount":1}
        ]
        """.data(using: .utf8)!
        let map = HistoryMenuController.titleMap(from: payload)
        #expect(map["https://a.example/"] == "A Page")
        // Normalized twin: trailing slash dropped.
        #expect(map["https://a.example"] == "A Page")
        // Untitled rows map nothing.
        #expect(map["https://b.example/x"] == nil)
    }

    @Test("the title line never repeats the address line")
    func displayTitleFallsBack() {
        let url = URL(string: "https://website.com/some/page")!
        #expect(HistoryMenuController.displayTitle(recorded: "Title Here", for: url) == "Title Here")
        #expect(HistoryMenuController.displayTitle(recorded: "", for: url) == "website.com")
        // The store records the address itself when the page had no
        // title: that reads as no title, not as one.
        #expect(HistoryMenuController.displayTitle(
            recorded: url.absoluteString, for: url) == "website.com")
    }

    @Test("the panel caps at seven rows, under the 350 cap")
    func heightCaps() {
        #expect(HistoryMenuList.height(forRowCount: 3) == CGFloat(3 * 44))
        #expect(HistoryMenuList.height(forRowCount: 7) == CGFloat(7 * 44))
        #expect(HistoryMenuList.height(forRowCount: 12) == CGFloat(7 * 44))
        #expect(HistoryMenuList.height(forRowCount: 12) <= 350)
    }
}
