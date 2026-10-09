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

/// What the editor card is editing.
enum BookmarkEditorMode: Equatable, Sendable {
    /// A new link, optionally prefilled (the star button) and filed under a
    /// folder (a context menu inside one).
    case newLink(prefillTitle: String, prefillURL: String, parentID: String?)
    /// A new folder, filed under the folder the context menu came from.
    case newFolder(parentID: String?)
    /// An existing bookmark or folder, looked up by id.
    case edit(id: String)

    var editedNodeID: String? {
        if case .edit(let id) = self { return id }
        return nil
    }
}

/// Applies editor submissions to the store.
///
/// Split from the card so the rules — what is valid, what a save changes,
/// which title a link falls back to — are testable without SwiftUI or XPC.
@MainActor
enum BookmarkEditor {
    /// The kind of thing `mode` edits; edit mode consults the store.
    static func kind(for mode: BookmarkEditorMode, in store: BookmarkStore) -> BookmarkNode.Kind {
        switch mode {
        case .newLink:
            return .link
        case .newFolder:
            return .folder
        case .edit(let id):
            return store.node(id)?.kind ?? .link
        }
    }

    /// A link needs an address, a folder a name. The link's title may stay
    /// empty: the store falls back to the host.
    static func isValid(title: String, url: String, kind: BookmarkNode.Kind) -> Bool {
        if kind == .folder {
            return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the star should open for `url`: an edit of the existing save, or
    /// a prefilled add.
    static func starMode(for url: URL, title: String, in store: BookmarkStore) -> BookmarkEditorMode {
        if let existing = store.bookmark(matching: url) {
            return .edit(id: existing.id)
        }
        return .newLink(prefillTitle: title, prefillURL: url.absoluteString, parentID: nil)
    }

    /// Applies a save. Returns the affected node's id, or nil when the
    /// submission was invalid or the edited node vanished.
    @discardableResult
    static func apply(
        title: String,
        url: String,
        parentID: String?,
        mode: BookmarkEditorMode,
        to store: BookmarkStore
    ) -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .newLink:
            guard !trimmedURL.isEmpty else { return nil }
            return store.createLink(title: trimmedTitle, url: trimmedURL, in: parentID)?.id

        case .newFolder:
            guard !trimmedTitle.isEmpty else { return nil }
            return store.createFolder(title: trimmedTitle, in: parentID)?.id

        case .edit(let id):
            guard let node = store.node(id) else { return nil }
            if node.isFolder {
                guard !trimmedTitle.isEmpty else { return nil }
                store.rename(id, title: trimmedTitle)
            } else {
                guard !trimmedURL.isEmpty else { return nil }
                let resolvedTitle = trimmedTitle.isEmpty
                    ? (URL(string: trimmedURL)?.host ?? trimmedURL)
                    : trimmedTitle
                store.rename(id, title: resolvedTitle)
                store.updateURL(id, url: trimmedURL)
            }
            if node.parentID != parentID {
                store.move(id, to: parentID)
            }
            return id
        }
    }
}
