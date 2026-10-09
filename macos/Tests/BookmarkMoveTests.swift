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

/// Store-level move semantics: reordering renumbers siblings, filing into
/// folders appends, and impossible moves are refused.
@MainActor
struct BookmarkMoveTests {
    private func makeStore(_ nodes: [BookmarkNode]) -> BookmarkStore {
        let store = BookmarkStore()
        store.persistEnabled = false
        store.replaceNodesForTesting(nodes)
        return store
    }

    private func rootNodes(_ ids: [String]) -> [BookmarkNode] {
        ids.enumerated().map { index, id in
            BookmarkNode(
                id: id,
                kind: .link,
                title: id.uppercased(),
                url: "https://\(id).example",
                order: Double(index)
            )
        }
    }

    @Test("reordering renumbers the siblings in their new sequence")
    func reorderRenumbers() {
        let store = makeStore(rootNodes(["a", "b", "c"]))
        store.move("c", to: nil, before: "a")
        #expect(store.roots.map(\.id) == ["c", "a", "b"])
        #expect(store.roots.map(\.order) == [0, 1, 2])
    }

    @Test("moving a link into a folder appends it there")
    func fileIntoFolder() {
        let store = makeStore([
            BookmarkNode(id: "f", kind: .folder, title: "Folder"),
            BookmarkNode(id: "l", kind: .link, title: "Link", url: "https://l.example"),
        ])
        store.move("l", to: "f")
        #expect(store.node("l")?.parentID == "f")
        #expect(store.children(of: "f").map(\.id) == ["l"])
        #expect(store.roots.map(\.id) == ["f"])
    }

    @Test("a folder cannot be filed into its own subtree")
    func refuseSelfSubtree() {
        let store = makeStore([
            BookmarkNode(id: "top", kind: .folder, title: "Top"),
            BookmarkNode(id: "mid", kind: .folder, title: "Mid", parentID: "top"),
        ])
        store.move("top", to: "mid")
        #expect(store.node("top")?.parentID == nil)
        #expect(store.children(of: "mid").isEmpty)
    }

    @Test("moving under a vanished parent is refused")
    func refuseMissingParent() {
        let store = makeStore(rootNodes(["a"]))
        store.move("a", to: "gone")
        #expect(store.node("a")?.parentID == nil)
    }

    @Test("reparenting keeps the moved node's place in the destination")
    func moveToRootMiddle() {
        let store = makeStore([
            BookmarkNode(id: "f", kind: .folder, title: "Folder"),
            BookmarkNode(id: "l", kind: .link, title: "Link", url: "https://l.example", parentID: "f"),
        ] + rootNodes(["a", "b"]).map { node in
            var copy = node
            copy.order += 1
            return copy
        })
        // Roots: a(1), b(2), f(0)? f has order 0, so root order is f, a, b.
        #expect(store.roots.map(\.id) == ["f", "a", "b"])
        store.move("l", to: nil, before: "b")
        #expect(store.roots.map(\.id) == ["f", "a", "l", "b"])
        #expect(store.node("l")?.parentID == nil)
    }
}

/// The bar's drag destinations: reorder edges, file-into-folder middles,
/// background appends, and the refusals.
@MainActor
struct BookmarkDragDestinationTests {
    private func makeBar() -> (BookmarkBarController, NSView) {
        let store = BookmarkStore()
        store.persistEnabled = false
        store.replaceNodesForTesting([
            BookmarkNode(id: "a", kind: .link, title: "A", url: "https://a.example", order: 0),
            BookmarkNode(id: "b", kind: .link, title: "B", url: "https://b.example", order: 1),
            BookmarkNode(id: "f", kind: .folder, title: "Folder", order: 2),
            BookmarkNode(id: "g", kind: .folder, title: "Other", order: 3),
            BookmarkNode(id: "l", kind: .link, title: "Inner", url: "https://l.example", parentID: "f"),
        ])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: BookmarkBarView.height))
        let bar = BookmarkBarController(container: container, store: store)
        bar.forceEnabledForTesting = true
        container.layoutSubtreeIfNeeded()
        return (bar, container)
    }

    @Test("the left half of an item inserts before it")
    func insertBefore() throws {
        let (bar, _) = makeBar()
        let view = bar.view
        let frame = try #require(view.itemFrameForTesting("a"))
        let point = NSPoint(x: frame.midX - 4, y: frame.midY)
        #expect(
            view.dropDestinationForTesting(at: point, draggedID: "b")
                == .reorder(parentID: nil, beforeID: "a")
        )
    }

    @Test("the right quarter of the last item appends at the end")
    func appendAtEnd() throws {
        let (bar, _) = makeBar()
        let view = bar.view
        let frame = try #require(view.itemFrameForTesting("g"))
        // The right quarter, not the middle: a folder's middle files into it.
        let point = NSPoint(x: frame.maxX - 3, y: frame.midY)
        #expect(
            view.dropDestinationForTesting(at: point, draggedID: "a")
                == .reorder(parentID: nil, beforeID: nil)
        )
    }

    @Test("a folder's middle files into it")
    func fileIntoFolder() throws {
        let (bar, _) = makeBar()
        let view = bar.view
        let frame = try #require(view.itemFrameForTesting("f"))
        let point = NSPoint(x: frame.midX, y: frame.midY)
        #expect(
            view.dropDestinationForTesting(at: point, draggedID: "a")
                == .intoFolder("f")
        )
    }

    @Test("the bar background appends at the end")
    func backgroundAppends() {
        let (bar, _) = makeBar()
        let view = bar.view
        let point = NSPoint(x: 20, y: 1)
        #expect(
            view.dropDestinationForTesting(at: point, draggedID: "a")
                == .reorder(parentID: nil, beforeID: nil)
        )
    }

    @Test("a folder dropped on itself has no destination")
    func selfDropRefused() throws {
        let (bar, _) = makeBar()
        let view = bar.view
        let frame = try #require(view.itemFrameForTesting("f"))
        let point = NSPoint(x: frame.midX, y: frame.midY)
        #expect(view.dropDestinationForTesting(at: point, draggedID: "f") == nil)
    }
}
