import Foundation
import WebKit

/// Session home for active downloads: owns every in-flight `WebDownload`,
/// resolves destinations, and retires interrupted rows.
///
/// One shared instance because downloads outlive tabs and navigations: closing
/// the tab that started a file must not kill the transfer, and progress for a
/// finished tab has nowhere else to go. The delegate owns nothing back, so
/// there is no cycle to break.
@MainActor
final class DownloadsCenter {
    static let shared = DownloadsCenter()

    private var active: [String: WebDownload] = [:]
    private let client: StoreClient
    private var reconciled = false

    init(client: StoreClient? = nil) {
        self.client = client ?? .shared
    }

    /// Starts tracking a `WKDownload` for a navigation response the policy
    /// handed off. Owns the operation until it finishes, fails, or cancels.
    func adopt(_ operation: WebDownload) {
        active[operation.id] = operation
    }

    /// Forgets a finished operation. Called by the operation itself.
    func retire(id: String) {
        active.removeValue(forKey: id)
    }

    /// Cancels an in-flight download, e.g. when its row is removed from the
    /// popup. The delegate's failure callback lands on the missing row and
    /// is ignored, so no phantom failed entry appears.
    func cancel(id: String) {
        active[id]?.cancel()
    }

    /// The folder downloads land in. Created on first use by `destination`.
    static nonisolated var downloadsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Destination for a download filename inside the downloads folder,
    /// de-duplicated (`report.pdf`, `report 2.pdf`, …) and created on demand.
    /// Static and nonisolated because the download delegate answers WebKit
    /// synchronously off the actor; the directory itself is user data outside
    /// any store, so it is made here, not in Nim.
    static nonisolated func destination(for filename: String) -> URL {
        let manager = FileManager.default
        let directory = downloadsDirectory
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let sanitized = filename
            .replacingOccurrences(of: "/", with: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "download" : sanitized
        var candidate = directory.appendingPathComponent(base, isDirectory: false)
        if !manager.fileExists(atPath: candidate.path) {
            return candidate
        }
        let stem = candidate.deletingPathExtension().lastPathComponent
        let suffix = candidate.pathExtension.isEmpty ? "" : ".\(candidate.pathExtension)"
        var counter = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(counter)\(suffix)", isDirectory: false)
            counter += 1
        }
        return candidate
    }

    /// Fails rows stuck in-progress from a previous launch (crash, kill,
    /// power loss): without this they would read as eternally downloading at
    /// whatever byte count they died on. Runs once per launch, before the
    /// first listing.
    func reconcileInterrupted() async {
        guard !reconciled else { return }
        reconciled = true
        do {
            let data = try await client.downloadHistory()
            for item in DownloadItem.decodeList(data) where item.state == .inProgress {
                try? await client.failDownload(
                    id: item.id,
                    error: "Interrupted",
                    bytesReceived: item.bytesReceived
                )
            }
        } catch {
            // A failed reconcile leaves the rows as they are; the next popup
            // open retries it through the same path.
        }
    }
}
