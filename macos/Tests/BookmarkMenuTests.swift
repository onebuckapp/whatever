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

/// The bookmark menus' structure: which commands exist for the bar, a link,
/// and a folder, and how folder contents nest.
@MainActor
struct BookmarkMenuTests {
    private func makeStore() -> BookmarkStore {
        let store = BookmarkStore()
        store.persistEnabled = false
        store.replaceNodesForTesting([
            BookmarkNode(id: "f", kind: .folder, title: "Folder", order: 0),
            BookmarkNode(id: "g", kind: .folder, title: "Nested", parentID: "f", order: 0),
            BookmarkNode(id: "h", kind: .link, title: "Deep Link", url: "https://deep.example", parentID: "g", order: 0),
            BookmarkNode(id: "l", kind: .link, title: "Link", url: "https://link.example", parentID: "f", order: 1),
        ])
        return store
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @Test("the bar menu offers creation and settings")
    func barMenu() {
        let target = BookmarkMenuTarget()
        let menu = BookmarkContextMenu.barMenu(target: target)
        #expect(titles(menu) == ["New Folder…", "New Bookmark…", "Open Bookmarks Settings"])
    }

    @Test("a link menu opens, copies, edits, and deletes")
    func linkMenu() {
        let store = makeStore()
        let target = BookmarkMenuTarget()
        let node = store.node("l")!
        let menu = BookmarkContextMenu.linkMenu(node: node, target: target)
        #expect(titles(menu) == ["Open", "Open in New Tab", "Copy Link", "Edit…", "Delete"])
        let payloads = menu.items.compactMap { $0.representedObject as? BookmarkMenuPayload }
        #expect(payloads.allSatisfy { $0.nodeID == "l" })
        #expect(payloads.map(\.action) == [.open, .openInNewTab, .copyURL, .edit, .delete])
    }

    @Test("a folder menu creates inside it and renames it")
    func folderMenu() {
        let store = makeStore()
        let target = BookmarkMenuTarget()
        let node = store.node("f")!
        let menu = BookmarkContextMenu.folderMenu(node: node, target: target)
        #expect(titles(menu) == [
            "Open All in New Tabs", "New Folder…", "New Bookmark…", "Rename…", "Delete",
        ])
        let payloads = menu.items.compactMap { $0.representedObject as? BookmarkMenuPayload }
        let newFolder = payloads.first { $0.action == .newFolder }
        #expect(newFolder?.parentID == "f")
        let rename = payloads.first { $0.action == .edit }
        #expect(rename?.nodeID == "f")
    }

    @Test("folder contents nest folders as submenus, in display order")
    func folderContents() {
        let store = makeStore()
        let target = BookmarkMenuTarget()
        let menu = BookmarkContextMenu.itemsMenu(
            parentID: "f",
            emptyTitle: "Empty",
            store: store,
            target: target
        )
        #expect(titles(menu) == ["Nested", "Link"])
        let nested = menu.items[0]
        let nestedTitles = titles(nested.submenu!)
        #expect(nestedTitles == ["Deep Link"])
        let deepPayload = nested.submenu!.items[0].representedObject as? BookmarkMenuPayload
        #expect(deepPayload?.action == .open)
        #expect(deepPayload?.nodeID == "h")
    }

    @Test("an empty folder's menu says so, disabled")
    func emptyFolder() {
        let store = BookmarkStore()
        store.persistEnabled = false
        store.replaceNodesForTesting([
            BookmarkNode(id: "f", kind: .folder, title: "Empty Folder"),
        ])
        let target = BookmarkMenuTarget()
        let menu = BookmarkContextMenu.itemsMenu(
            parentID: "f",
            emptyTitle: "Empty",
            store: store,
            target: target
        )
        #expect(menu.items.count == 1)
        #expect(menu.items[0].title == "Empty")
        #expect(!menu.items[0].isEnabled)
    }
}
