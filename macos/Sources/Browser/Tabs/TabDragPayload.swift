import AppKit

/// Drag payload for tab moves. Only the tab's identifier travels on the
/// pasteboard, never the tab model: the receiving side resolves the
/// identifier back to the live tab so its web view is moved rather than
/// recreated.
enum TabDragPayload {
    static let type = NSPasteboard.PasteboardType(
        rawValue: "com.onebuckapps.whatever.tab-id"
    )

    static func pasteboard(for tab: BrowserTab) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        pasteboard.setString(tab.id.uuidString, forType: type)
        return pasteboard
    }

    /// Resolves a dragging tab, rejecting drags that started in another
    /// app or from a tab that no longer exists.
    @MainActor
    static func tab(from info: NSDraggingInfo) -> BrowserTab? {
        guard let string = info.draggingPasteboard.string(forType: type) else {
            return nil
        }
        return BrowserCoordinator.shared.tab(withIDString: string)
    }
}
