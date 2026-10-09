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
import Combine

/// The app's bookmarks, loaded once and mutated locally.
///
/// App-wide rather than per window, because bookmarks are: the bar, the
/// star, the editor, and the settings pane all observe the same instance
/// and the same changes.
///
/// Writes are optimistic — the local dictionary changes first, the store
/// follows behind — and a failed write reloads from the store so the UI
/// heals to persisted truth instead of drifting. Each bookmark is its own
/// document, so a move that renumbers siblings is a handful of independent
/// writes; that is the docstore's grain and the data is tiny.
@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    /// Every bookmark keyed by id. Read through `roots`/`children(of:)`,
    /// which apply the arrangement rules.
    @Published private(set) var nodes: [String: BookmarkNode] = [:]
    @Published private(set) var isLoaded = false
    @Published private(set) var lastError: String?

    private let client: StoreClient
    private var isLoading = false

    /// Test seam: when false, mutations change only the in-memory model and
    /// never touch the store service.
    var persistEnabled = true

    /// `client` defaults to the shared client when nil: spelled this way
    /// rather than `= .shared` so the main-actor-isolated singleton is only
    /// touched from inside the isolated init body.
    init(client: StoreClient? = nil) {
        self.client = client ?? .shared
    }

    // MARK: - Reading

    /// Root-level bookmarks in display order.
    var roots: [BookmarkNode] { BookmarkTree.children(of: nil, in: nodes) }

    func children(of parentID: String?) -> [BookmarkNode] {
        BookmarkTree.children(of: parentID, in: nodes)
    }

    func node(_ id: String) -> BookmarkNode? { nodes[id] }

    /// The first link whose normalized URL matches. Duplicates are allowed
    /// (a page may sit in two folders), so "first" is display order.
    func bookmark(matching url: URL) -> BookmarkNode? {
        let key = BookmarkURL.normalized(url)
        return nodes.values.first {
            $0.kind == .link && $0.url.map(BookmarkURL.normalized) == key
        }
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmark(matching: url) != nil
    }

    /// Folder picker entries in display order, excluding `excludedID`'s own
    /// subtree so an edit can never file a folder inside itself.
    func folderChoices(excluding excludedID: String?) -> [BookmarkTree.FolderChoice] {
        let banned = excludedID.map {
            BookmarkTree.descendantIDs(of: $0, in: nodes).union([$0])
        } ?? []
        return BookmarkTree.foldersDepthFirst(in: nodes).filter { !banned.contains($0.node.id) }
    }

    /// Test seam: sets bookmarks without the store service, so model and
    /// layout tests can drive the chrome without XPC.
    func replaceNodesForTesting(_ nodes: [BookmarkNode]) {
        self.nodes = BookmarkTree.sanitized(
            Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        )
        isLoaded = true
        lastError = nil
    }

    /// Reloads from the persisted store. Failures keep the previous content
    /// and surface in `lastError`: a transient XPC hiccup must not blank the
    /// bar. Concurrent calls collapse into one.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await client.bookmarks()
            let decoded = BookmarkNode.decodeList(data)
            nodes = BookmarkTree.sanitized(
                Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isLoaded = true
    }

    // MARK: - Mutations

    @discardableResult
    func createLink(title: String, url: String, in parentID: String? = nil) -> BookmarkNode? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = BookmarkNode(
            id: UUID().uuidString,
            kind: .link,
            title: trimmedTitle.isEmpty
                ? (URL(string: trimmedURL)?.host ?? trimmedURL)
                : trimmedTitle,
            url: trimmedURL,
            parentID: validParent(parentID),
            order: BookmarkTree.nextOrder(in: validParent(parentID), nodes: nodes),
            createdAt: Int64(Date().timeIntervalSince1970)
        )
        nodes[node.id] = node
        persist([node.id])
        return node
    }

    @discardableResult
    func createFolder(title: String, in parentID: String? = nil) -> BookmarkNode? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = BookmarkNode(
            id: UUID().uuidString,
            kind: .folder,
            title: trimmed.isEmpty ? "New Folder" : trimmed,
            parentID: validParent(parentID),
            order: BookmarkTree.nextOrder(in: validParent(parentID), nodes: nodes),
            createdAt: Int64(Date().timeIntervalSince1970)
        )
        nodes[node.id] = node
        persist([node.id])
        return node
    }

    func rename(_ id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var node = nodes[id], node.title != trimmed else { return }
        node.title = trimmed
        nodes[id] = node
        persist([id])
    }

    func updateURL(_ id: String, url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var node = nodes[id],
              node.kind == .link,
              node.url != trimmed
        else {
            return
        }
        node.url = trimmed
        nodes[id] = node
        persist([id])
    }

    /// Moves `id` to `parentID`, just before `beforeID` (nil appends at the
    /// end). The destination's children are renumbered in their new sequence
    /// and only the ones whose order actually changed are written.
    func move(_ id: String, to parentID: String?, before beforeID: String? = nil) {
        guard let node = nodes[id],
              !BookmarkTree.invalidMove(id: id, to: parentID, in: nodes)
        else {
            return
        }

        // Reparent first, then renumber: the moved node takes its place in
        // the destination's sequence below and must not be clobbered after.
        let reparented = node.parentID != parentID
        if reparented {
            var moved = node
            moved.parentID = parentID
            nodes[id] = moved
        }

        let siblings = BookmarkTree.reorderedChildren(
            in: parentID,
            moving: id,
            before: beforeID,
            in: nodes
        )
        var changed: [String] = []
        for (index, sibling) in siblings.enumerated() {
            guard var current = nodes[sibling.id] else { continue }
            let newOrder = Double(index)
            if current.order != newOrder {
                current.order = newOrder
                nodes[sibling.id] = current
                changed.append(sibling.id)
            }
        }
        if reparented, !changed.contains(id) {
            changed.append(id)
        }
        persist(changed)
    }

    /// Deletes a bookmark, or a folder with everything inside it.
    func delete(_ id: String) {
        guard nodes[id] != nil else { return }
        let doomed = BookmarkTree.descendantIDs(of: id, in: nodes).union([id])
        nodes = nodes.filter { !doomed.contains($0.key) }
        guard persistEnabled else { return }
        Task {
            do {
                for victim in doomed {
                    try await client.deleteBookmark(id: victim)
                }
            } catch {
                lastError = error.localizedDescription
                await load()
            }
        }
    }

    func removeAll() {
        nodes = [:]
        guard persistEnabled else { return }
        Task {
            do {
                try await client.clearBookmarks()
            } catch {
                lastError = error.localizedDescription
                await load()
            }
        }
    }

    // MARK: - Persistence

    /// A parent that is actually a folder, else the root level.
    private func validParent(_ parentID: String?) -> String? {
        guard let parentID, nodes[parentID]?.kind == .folder else { return nil }
        return parentID
    }

    private func persist(_ ids: [String]) {
        let documents: [(String, Data)] = ids.compactMap { id in
            guard let node = nodes[id], let data = try? JSONEncoder().encode(node) else {
                return nil
            }
            return (id, data)
        }
        guard !documents.isEmpty else { return }
        guard persistEnabled else { return }
        Task {
            do {
                for (id, data) in documents {
                    try await client.setBookmark(id: id, document: data)
                }
            } catch {
                lastError = error.localizedDescription
                await load()
            }
        }
    }
}
