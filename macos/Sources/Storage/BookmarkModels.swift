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

/// One bookmark: a link or a folder.
///
/// The core stores one JSON document per bookmark keyed by a string id and
/// only ever sees the document as an opaque object, so the shape here *is*
/// the persistence format. Two rules come from that:
///
/// - The document must carry its own `id`. `bookmarkList` emits values only,
///   never the docstore key, so a document without `id` is undecodable.
/// - Ordering is client-side. The backing docstore iterates in key order
///   (UUID strings), not insertion order, so `parentID` + `order` carry the
///   arrangement and `BookmarkTree` sorts on read.
///
/// Decoding is tolerant in the same spirit as the feed models: a document
/// written before folders existed has no `kind`/`parentID`/`order`, and reads
/// as a root-level link rather than failing the whole list.
struct BookmarkNode: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case link
        case folder
    }

    let id: String
    var kind: Kind
    var title: String
    /// Links only. Nil (or absent) on folders.
    var url: String?
    /// Parent folder, or nil for the root level.
    var parentID: String?
    /// Position hint among siblings, low to high. Renumbered on moves.
    var order: Double
    /// Unix seconds, for a stable tiebreak and future "sort by date added".
    var createdAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, url, parentID, order, createdAt
    }

    init(
        id: String,
        kind: Kind,
        title: String,
        url: String? = nil,
        parentID: String? = nil,
        order: Double = 0,
        createdAt: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.parentID = parentID
        self.order = order
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .link
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        url = try? container.decode(String.self, forKey: .url)
        parentID = try? container.decode(String.self, forKey: .parentID)
        order = (try? container.decode(Double.self, forKey: .order)) ?? 0
        createdAt = try? container.decode(Int64.self, forKey: .createdAt)
    }

    var isFolder: Bool { kind == .folder }

    /// What the chrome shows when a title was never set.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let url, !url.isEmpty { return url }
        return "Untitled"
    }

    /// Decodes a stored array, skipping rows that are not bookmark objects.
    /// One malformed document costs that bookmark, not the list.
    static func decodeList(_ data: Data) -> [BookmarkNode] {
        (try? JSONDecoder().decode([Failable].self, from: data))?.compactMap(\.value) ?? []
    }

    private struct Failable: Decodable {
        let value: BookmarkNode?

        init(from decoder: Decoder) throws {
            value = try? BookmarkNode(from: decoder)
        }
    }
}

/// URL identity for bookmark matching.
///
/// The star's filled state and duplicate checks compare pages by this
/// normalized form, not by raw string: scheme and host case, a trailing
/// slash, and the fragment are all noise for "is this page bookmarked".
enum BookmarkURL {
    static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path == "/" {
            components.path = ""
        }
        return components.string ?? trimmed
    }

    static func normalized(_ url: URL) -> String {
        normalized(url.absoluteString)
    }
}

/// Tree operations over the flat node dictionary.
///
/// Pure and static: the store applies the results and persists them, so the
/// arrangement rules are testable without XPC. Every read sorts explicitly,
/// because the backing store hands documents back in key order.
enum BookmarkTree {
    /// Children of a folder in display order. `parentID == nil` is the root
    /// level.
    static func children(of parentID: String?, in nodes: [String: BookmarkNode]) -> [BookmarkNode] {
        nodes.values
            .filter { $0.parentID == parentID }
            .sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                let left = $0.title.lowercased()
                let right = $1.title.lowercased()
                if left != right { return left < right }
                return $0.id < $1.id
            }
    }

    /// Next append position among a folder's children.
    static func nextOrder(in parentID: String?, nodes: [String: BookmarkNode]) -> Double {
        (children(of: parentID, in: nodes).map(\.order).max() ?? -1) + 1
    }

    /// Every descendant of `id`, not including `id` itself.
    static func descendantIDs(of id: String, in nodes: [String: BookmarkNode]) -> Set<String> {
        var result: Set<String> = []
        var frontier = [id]
        while let current = frontier.popLast() {
            for child in children(of: current, in: nodes) where result.insert(child.id).inserted {
                frontier.append(child.id)
            }
        }
        return result
    }

    /// Whether `id` is `ancestorID` or sits somewhere under it.
    static func isDescendant(_ id: String, of ancestorID: String, in nodes: [String: BookmarkNode]) -> Bool {
        id == ancestorID || descendantIDs(of: ancestorID, in: nodes).contains(id)
    }

    /// Repairs a freshly loaded dictionary: a node whose parent is missing or
    /// is not a folder goes to the root, and so does a node caught in a
    /// parent cycle. Hand-edited or corrupted documents must never make
    /// bookmarks unreachable.
    static func sanitized(_ nodes: [String: BookmarkNode]) -> [String: BookmarkNode] {
        var result = nodes
        for (id, node) in nodes {
            guard let parentID = node.parentID else { continue }
            guard nodes[parentID]?.kind == .folder else {
                result[id]?.parentID = nil
                continue
            }
            var seen: Set<String> = [id]
            var current: String? = parentID
            while let step = current {
                guard seen.insert(step).inserted else {
                    result[id]?.parentID = nil
                    break
                }
                current = nodes[step]?.parentID
            }
        }
        return result
    }

    /// The destination folder's children after moving `id` to just before
    /// `beforeID` (nil appends at the end). Includes the moved node.
    static func reorderedChildren(
        in parentID: String?,
        moving id: String,
        before beforeID: String?,
        in nodes: [String: BookmarkNode]
    ) -> [BookmarkNode] {
        var siblings = children(of: parentID, in: nodes).filter { $0.id != id }
        guard let moved = nodes[id] else { return siblings }
        if let beforeID, let index = siblings.firstIndex(where: { $0.id == beforeID }) {
            siblings.insert(moved, at: index)
        } else {
            siblings.append(moved)
        }
        return siblings
    }

    /// Whether `id` may be filed under `parentID`. Refuses unknown nodes,
    /// non-folder parents, and any move that would put a folder inside
    /// itself or its own subtree.
    static func invalidMove(
        id: String,
        to parentID: String?,
        in nodes: [String: BookmarkNode]
    ) -> Bool {
        guard nodes[id] != nil else { return true }
        guard let parentID else { return false }
        guard nodes[parentID]?.kind == .folder else { return true }
        return isDescendant(parentID, of: id, in: nodes)
    }

    /// A folder in tree order, for pickers and nested views.
    struct FolderChoice: Identifiable, Equatable, Sendable {
        let node: BookmarkNode
        let depth: Int

        var id: String { node.id }
    }

    /// Every folder, depth-first, with its indentation depth. Root folders
    /// are depth 0; a folder's subfolders follow it before its next sibling.
    static func foldersDepthFirst(in nodes: [String: BookmarkNode]) -> [FolderChoice] {
        var result: [FolderChoice] = []
        func walk(_ parentID: String?, _ depth: Int) {
            for child in children(of: parentID, in: nodes) where child.kind == .folder {
                result.append(FolderChoice(node: child, depth: depth))
                walk(child.id, depth + 1)
            }
        }
        walk(nil, 0)
        return result
    }
}
