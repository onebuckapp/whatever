import Combine
import Foundation

/// Session "seen" state behind the Downloads button badge.
///
/// Counts downloads that finished while the popup stayed closed. In-memory
/// only: a new launch starts clean, which is exactly the current-session
/// semantics the badge promises, with no migration and nothing to persist.
/// Shared across windows, so opening the popup anywhere clears every badge.
@MainActor
final class DownloadsBadgeCenter: ObservableObject {
    static let shared = DownloadsBadgeCenter()

    /// Finished-but-unseen downloads this session. Zero hides the badge.
    @Published private(set) var unseenCount = 0

    private var unseenIDs = Set<String>()

    /// Records a finished download as unseen. Failed and cancelled rows do
    /// not badge: they surface through retry inside the popup instead.
    func noteFinished(id: String) {
        if unseenIDs.insert(id).inserted {
            unseenCount = unseenIDs.count
        }
    }

    /// Clears the badge. Called when the popup opens.
    func markAllSeen() {
        unseenIDs.removeAll()
        unseenCount = 0
    }
}
