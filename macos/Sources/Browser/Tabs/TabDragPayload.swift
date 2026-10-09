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

/// Drag payload for tab moves. Only the tab's identifier travels on the
/// pasteboard, never the tab model: the receiving side resolves the
/// identifier back to the live tab so its web view is moved rather than
/// recreated.
enum TabDragPayload {
    static let type = NSPasteboard.PasteboardType(
        rawValue: "com.onebuckapp.whatever.tab-id"
    )

    static func pasteboard(for tab: BrowserTab) -> NSPasteboard {
        pasteboard(for: [tab])
    }

    /// Pasteboard carrying a whole split group, in pane order. One tab and
    /// one group share the pasteboard type: a single ID reads as a lone tab
    /// everywhere, two as the group.
    static func pasteboard(for tabs: [BrowserTab]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        pasteboard.setString(
            tabs.map(\.id.uuidString).joined(separator: "\n"),
            forType: type
        )
        return pasteboard
    }

    /// Resolves a dragging tab, rejecting drags that started in another
    /// app or from a tab that no longer exists.
    @MainActor
    static func tab(from info: NSDraggingInfo) -> BrowserTab? {
        tabs(from: info).first
    }

    /// Resolves every dragged tab, in the order written. Empty when the
    /// drag came from elsewhere or nothing in it still exists.
    @MainActor
    static func tabs(from info: NSDraggingInfo) -> [BrowserTab] {
        guard let string = info.draggingPasteboard.string(forType: type) else {
            return []
        }
        return string
            .split(separator: "\n")
            .compactMap { BrowserCoordinator.shared.tab(withIDString: String($0)) }
    }
}
