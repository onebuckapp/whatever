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

/// Drag payload for bookmark moves. Only the bookmark's id travels on the
/// pasteboard, never the model: the receiving side resolves the id against
/// the live store, so a drop always moves what is actually there.
enum BookmarkDragPayload {
    static let type = NSPasteboard.PasteboardType(
        rawValue: "com.onebuckapp.whatever.bookmark-id"
    )

    /// Resolves the dragged bookmark, rejecting drags that started in
    /// another app or for a bookmark that no longer exists.
    @MainActor
    static func node(from info: NSDraggingInfo, in store: BookmarkStore) -> BookmarkNode? {
        guard let id = info.draggingPasteboard.string(forType: type) else { return nil }
        return store.node(id)
    }
}

/// A pasteboard writer for one bookmark id.
@MainActor
final class BookmarkPasteboardItem: NSObject, NSPasteboardWriting {
    let id: String

    init(id: String) {
        self.id = id
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [BookmarkDragPayload.type]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == BookmarkDragPayload.type ? id : nil
    }
}

/// Where a bookmark drag would land.
enum BookmarkDropDestination: Equatable {
    /// Insert just before `beforeID` among `parentID`'s children; nil
    /// `beforeID` appends at the end.
    case reorder(parentID: String?, beforeID: String?)
    /// File into a folder, appended at its end.
    case intoFolder(String)
}
