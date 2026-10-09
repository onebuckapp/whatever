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

/// The bookmark tree rules: ordering, sanitizing, moves, and folder walks.
struct BookmarkTreeTests {
    private func link(
        _ id: String,
        title: String = "",
        parent: String? = nil,
        order: Double = 0,
        url: String? = "https://example.com"
    ) -> BookmarkNode {
        BookmarkNode(id: id, kind: .link, title: title, url: url, parentID: parent, order: order)
    }

    private func folder(
        _ id: String,
        title: String = "",
        parent: String? = nil,
        order: Double = 0
    ) -> BookmarkNode {
        BookmarkNode(id: id, kind: .folder, title: title, parentID: parent, order: order)
    }

    private func dict(_ nodes: [BookmarkNode]) -> [String: BookmarkNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    @Test("children sort by order, then title")
    func childOrder() {
        let nodes = dict([
            link("c", title: "Zebra", parent: "root", order: 1),
            link("b", title: "Apple", parent: "root", order: 1),
            link("a", title: "Middle", parent: "root", order: 0),
            link("x", title: "Root level", order: 0),
        ])
        let children = BookmarkTree.children(of: "root", in: nodes)
        #expect(children.map(\.id) == ["a", "b", "c"])
        #expect(BookmarkTree.children(of: nil, in: nodes).map(\.id) == ["x"])
    }

    @Test("next append position follows the highest sibling order")
    func nextOrder() {
        let nodes = dict([
            link("a", parent: "f", order: 0),
            link("b", parent: "f", order: 4.5),
        ])
        #expect(BookmarkTree.nextOrder(in: "f", nodes: nodes) == 5.5)
        #expect(BookmarkTree.nextOrder(in: nil, nodes: nodes) == 0)
    }

    @Test("orphans and link-parented nodes fall to the root")
    func sanitizeOrphans() {
        let nodes = dict([
            link("a", parent: "missing"),
            link("b", parent: "notAFolder"),
            link("notAFolder", url: nil),
            link("c", title: "kept", parent: "folder"),
            folder("folder"),
        ])
        let clean = BookmarkTree.sanitized(nodes)
        #expect(clean["a"]?.parentID == nil)
        #expect(clean["b"]?.parentID == nil)
        #expect(clean["c"]?.parentID == "folder")
    }

    @Test("a parent cycle puts the caught node at the root")
    func sanitizeCycle() {
        let nodes = dict([
            folder("a", parent: "b"),
            folder("b", parent: "a"),
        ])
        let clean = BookmarkTree.sanitized(nodes)
        // Whatever the promotion chose, every chain now terminates.
        for id in ["a", "b"] {
            var seen: Set<String> = []
            var current: String? = id
            while let step = current {
                #expect(seen.insert(step).inserted, "cycle survived at \(step)")
                current = clean[step]?.parentID
            }
        }
    }

    @Test("reordering inserts before the target, or appends")
    func reorder() {
        let nodes = dict([
            link("a", parent: nil, order: 0),
            link("b", parent: nil, order: 1),
            link("c", parent: nil, order: 2),
        ])
        let moved = BookmarkTree.reorderedChildren(
            in: nil, moving: "c", before: "a", in: nodes
        )
        #expect(moved.map(\.id) == ["c", "a", "b"])

        let appended = BookmarkTree.reorderedChildren(
            in: nil, moving: "a", before: nil, in: nodes
        )
        #expect(appended.map(\.id) == ["b", "c", "a"])
    }

    @Test("descendants cover a whole subtree, not just direct children")
    func descendants() {
        let nodes = dict([
            folder("top"),
            folder("mid", parent: "top"),
            link("leaf", parent: "mid"),
            link("other", parent: "top"),
        ])
        #expect(BookmarkTree.descendantIDs(of: "top", in: nodes) == ["mid", "leaf", "other"])
        #expect(BookmarkTree.isDescendant("leaf", of: "top", in: nodes))
        #expect(BookmarkTree.isDescendant("top", of: "top", in: nodes))
        #expect(!BookmarkTree.isDescendant("other", of: "mid", in: nodes))
    }

    @Test("moves into self, a descendant, or a link are refused")
    func invalidMoves() {
        let nodes = dict([
            folder("top"),
            folder("mid", parent: "top"),
            link("leaf", parent: "mid"),
            link("page"),
        ])
        #expect(BookmarkTree.invalidMove(id: "top", to: "top", in: nodes))
        #expect(BookmarkTree.invalidMove(id: "top", to: "mid", in: nodes))
        #expect(BookmarkTree.invalidMove(id: "top", to: "leaf", in: nodes))
        #expect(BookmarkTree.invalidMove(id: "unknown", to: nil, in: nodes))
        #expect(!BookmarkTree.invalidMove(id: "page", to: "mid", in: nodes))
        #expect(!BookmarkTree.invalidMove(id: "mid", to: nil, in: nodes))
    }

    @Test("folders list depth-first with their depth")
    func foldersDepthFirst() {
        let nodes = dict([
            folder("b", title: "Beta", order: 1),
            folder("a", title: "Alpha", order: 0),
            folder("a1", parent: "a"),
            folder("a1x", parent: "a1"),
            link("link", parent: "a"),
        ])
        let folders = BookmarkTree.foldersDepthFirst(in: nodes)
        #expect(folders.map(\.node.id) == ["a", "a1", "a1x", "b"])
        #expect(folders.map(\.depth) == [0, 1, 2, 0])
    }

    @Test("legacy documents read as root-level links")
    func legacyDecode() {
        let data = Data(#"[{"id":"a","title":"Whatever","url":"https://onebuck.app"}]"#.utf8)
        let decoded = BookmarkNode.decodeList(data)
        #expect(decoded.count == 1)
        #expect(decoded[0].kind == .link)
        #expect(decoded[0].parentID == nil)
        #expect(decoded[0].order == 0)
        #expect(decoded[0].url == "https://onebuck.app")
    }

    @Test("malformed rows cost themselves, not the list")
    func decodeTolerance() {
        let data = Data(#"[{"title":"no id"},{"id":"b","kind":"folder"}]"#.utf8)
        let decoded = BookmarkNode.decodeList(data)
        #expect(decoded.count == 1)
        #expect(decoded[0].id == "b")
        #expect(decoded[0].isFolder)
    }

    @Test("URL matching ignores case, fragment, and a bare trailing slash")
    func urlNormalization() {
        #expect(
            BookmarkURL.normalized("HTTPS://Example.com/Path#frag")
                == BookmarkURL.normalized("https://example.com/Path")
        )
        #expect(
            BookmarkURL.normalized("https://example.com/")
                == BookmarkURL.normalized("https://example.com")
        )
        #expect(
            BookmarkURL.normalized("https://example.com/a")
                != BookmarkURL.normalized("https://example.com/b")
        )
    }

    @MainActor
    @Test("the store matches the star state by normalized URL")
    func storeMatching() {
        let store = BookmarkStore()
        store.replaceNodesForTesting([
            link("a", title: "Saved", url: "https://Example.com/page#section"),
        ])
        #expect(store.isBookmarked(URL(string: "https://example.com/page")!))
        #expect(!store.isBookmarked(URL(string: "https://example.com/other")!))
        #expect(store.bookmark(matching: URL(string: "https://EXAMPLE.com/page")!)?.id == "a")
    }

    @MainActor
    @Test("folder choices exclude the edited node's own subtree")
    func folderChoices() {
        let store = BookmarkStore()
        store.replaceNodesForTesting([
            folder("top", title: "Top", order: 0),
            folder("mid", title: "Mid", parent: "top"),
            folder("other", title: "Other", order: 1),
        ])
        let forNew = store.folderChoices(excluding: nil).map(\.node.id)
        #expect(forNew == ["top", "mid", "other"])
        let forEdit = store.folderChoices(excluding: "top").map(\.node.id)
        #expect(forEdit == ["other"])
    }
}
