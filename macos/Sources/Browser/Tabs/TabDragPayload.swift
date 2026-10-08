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
