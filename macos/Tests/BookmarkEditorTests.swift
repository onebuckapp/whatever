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

/// Editor rules: what a save creates, changes, and refuses.
@MainActor
struct BookmarkEditorTests {
    private func link(
        _ id: String,
        title: String = "",
        parent: String? = nil,
        url: String? = "https://example.com"
    ) -> BookmarkNode {
        BookmarkNode(id: id, kind: .link, title: title, url: url, parentID: parent)
    }

    private func folder(_ id: String, title: String = "", parent: String? = nil) -> BookmarkNode {
        BookmarkNode(id: id, kind: .folder, title: title, parentID: parent)
    }

    private func makeStore(_ nodes: [BookmarkNode]) -> BookmarkStore {
        let store = BookmarkStore()
        store.persistEnabled = false
        store.replaceNodesForTesting(nodes)
        return store
    }

    @Test("validity: links need an address, folders a name")
    func validity() {
        #expect(BookmarkEditor.isValid(title: "", url: "https://x", kind: .link))
        #expect(!BookmarkEditor.isValid(title: "Titled", url: "   ", kind: .link))
        #expect(BookmarkEditor.isValid(title: "Name", url: "", kind: .folder))
        #expect(!BookmarkEditor.isValid(title: "   ", url: "https://x", kind: .folder))
    }

    @Test("a new link files into the folder and falls back to the host")
    func createLink() throws {
        let store = makeStore([folder("f", title: "Folder")])
        let id = try #require(
            BookmarkEditor.apply(
                title: "",
                url: "https://example.com/page",
                parentID: "f",
                mode: .newLink(prefillTitle: "", prefillURL: "", parentID: "f"),
                to: store
            )
        )
        let node = try #require(store.node(id))
        #expect(node.kind == .link)
        #expect(node.parentID == "f")
        #expect(node.title == "example.com")
        #expect(node.url == "https://example.com/page")
    }

    @Test("a new folder takes its name and parent")
    func createFolder() throws {
        let store = makeStore([folder("f", title: "Folder")])
        let id = try #require(
            BookmarkEditor.apply(
                title: "  Recipes  ",
                url: "",
                parentID: "f",
                mode: .newFolder(parentID: "f"),
                to: store
            )
        )
        let node = try #require(store.node(id))
        #expect(node.isFolder)
        #expect(node.title == "Recipes")
        #expect(node.parentID == "f")
    }

    @Test("a new item under a vanished folder lands at the root")
    func createUnderMissingParent() throws {
        let store = makeStore([])
        let id = try #require(
            BookmarkEditor.apply(
                title: "Saved",
                url: "https://example.com",
                parentID: "gone",
                mode: .newFolder(parentID: "gone"),
                to: store
            )
        )
        #expect(try #require(store.node(id)).parentID == nil)
    }

    @Test("editing a link renames, retargets, and moves it")
    func editLink() throws {
        let store = makeStore([
            folder("f", title: "Folder"),
            link("l", title: "Old", url: "https://old.example"),
        ])
        let id = try #require(
            BookmarkEditor.apply(
                title: "New",
                url: "https://new.example",
                parentID: "f",
                mode: .edit(id: "l"),
                to: store
            )
        )
        let node = try #require(store.node(id))
        #expect(node.title == "New")
        #expect(node.url == "https://new.example")
        #expect(node.parentID == "f")
    }

    @Test("editing a link with an empty title falls back to the host")
    func editLinkEmptyTitle() throws {
        let store = makeStore([link("l", title: "Old", url: "https://old.example")])
        _ = BookmarkEditor.apply(
            title: "   ",
            url: "https://new.example/path",
            parentID: nil,
            mode: .edit(id: "l"),
            to: store
        )
        #expect(try #require(store.node("l")).title == "new.example")
    }

    @Test("editing a folder renames it and refuses a move into its own subtree")
    func editFolderRefusesSelfMove() throws {
        let store = makeStore([
            folder("top", title: "Top"),
            folder("mid", title: "Mid", parent: "top"),
        ])
        _ = BookmarkEditor.apply(
            title: "Top!",
            url: "",
            parentID: "mid",
            mode: .edit(id: "top"),
            to: store
        )
        let node = try #require(store.node("top"))
        #expect(node.title == "Top!")
        #expect(node.parentID == nil)
    }

    @Test("an invalid submission changes nothing")
    func invalidSubmission() {
        let store = makeStore([link("l", title: "Old", url: "https://old.example")])
        let before = store.nodes
        let result = BookmarkEditor.apply(
            title: "T",
            url: "   ",
            parentID: nil,
            mode: .edit(id: "l"),
            to: store
        )
        #expect(result == nil)
        #expect(store.nodes == before)
    }

    @Test("the star edits a saved page and prefills an unsaved one")
    func starMode() throws {
        let store = makeStore([link("l", title: "Saved", url: "https://example.com/page")])
        let saved = BookmarkEditor.starMode(
            for: URL(string: "https://example.com/page#frag")!,
            title: "Whatever",
            in: store
        )
        #expect(saved == .edit(id: "l"))

        let fresh = BookmarkEditor.starMode(
            for: URL(string: "https://other.example/x")!,
            title: "Other",
            in: store
        )
        guard case .newLink(let title, let url, let parent) = fresh else {
            Issue.record("expected a prefilled add, got \(fresh)")
            return
        }
        #expect(title == "Other")
        #expect(url == "https://other.example/x")
        #expect(parent == nil)
    }
}
