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
import Foundation
import Testing
@testable import Whatever

/// Split anchoring: the context menu acts on the clicked tab, never on the
/// selection, and the last tab has no next sibling to split with. Pure
/// sibling resolution, no window needed.
@MainActor
struct SplitAnchorTests {
    private final class StubHistory: HistoryRecording {
        func record(url: URL, title: String?) {}
    }

    private func makeTabs(_ count: Int) -> [BrowserTab] {
        (0..<count).map { _ in BrowserTab(privacyMode: .regular, history: StubHistory()) }
    }

    @Test("next sibling resolves inside the bar")
    func nextSibling() {
        let tabs = makeTabs(3)
        #expect(BrowserWindowController.nextTab(after: tabs[0], in: tabs)?.id == tabs[1].id)
        #expect(BrowserWindowController.nextTab(after: tabs[1], in: tabs)?.id == tabs[2].id)
    }

    @Test("the last tab has no next sibling")
    func lastTabHasNoNext() {
        let tabs = makeTabs(3)
        #expect(BrowserWindowController.nextTab(after: tabs[2], in: tabs) == nil)
    }

    @Test("previous sibling resolves inside the bar")
    func previousSibling() {
        let tabs = makeTabs(3)
        #expect(BrowserWindowController.previousTab(before: tabs[2], in: tabs)?.id == tabs[1].id)
        #expect(BrowserWindowController.previousTab(before: tabs[1], in: tabs)?.id == tabs[0].id)
    }

    @Test("the first tab has no previous sibling")
    func firstTabHasNoPrevious() {
        let tabs = makeTabs(3)
        #expect(BrowserWindowController.previousTab(before: tabs[0], in: tabs) == nil)
    }

    @Test("a tab outside the window has neither sibling")
    func foreignTabHasNoSiblings() {
        let tabs = makeTabs(2)
        let foreign = makeTabs(1)[0]
        #expect(BrowserWindowController.nextTab(after: foreign, in: tabs) == nil)
        #expect(BrowserWindowController.previousTab(before: foreign, in: tabs) == nil)
    }

    @Test("a lone tab has neither sibling")
    func loneTabHasNoSiblings() {
        let tabs = makeTabs(1)
        #expect(BrowserWindowController.nextTab(after: tabs[0], in: tabs) == nil)
        #expect(BrowserWindowController.previousTab(before: tabs[0], in: tabs) == nil)
    }
}
