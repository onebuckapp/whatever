import Foundation

/// A finished page visit.
struct HistoryEntry: Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let visitedAt: Date
}

/// Seam for persistent history. The in-memory recorder below is temporary;
/// when `core/` ships `libbrowsercore.a`, add a `NimHistoryRecorder`
/// conformance that calls `history_add(url, title, timestamp)` through
/// `browsercore.h` without touching the tab layer.
protocol HistoryRecording: AnyObject {
    func record(url: URL, title: String?)
}

/// Temporary Swift-only history. Called on the main thread.
final class InMemoryHistoryRecorder: HistoryRecording {
    private(set) var entries: [HistoryEntry] = []

    func record(url: URL, title: String?) {
        entries.append(
            HistoryEntry(
                id: UUID(),
                url: url,
                title: title ?? url.absoluteString,
                visitedAt: Date()
            )
        )
    }
}
