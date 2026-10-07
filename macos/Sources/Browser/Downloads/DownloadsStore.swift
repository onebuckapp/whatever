import Combine
import Foundation

/// Download history for the popup, read from the store service.
///
/// Separate from the recording path (the `WKDownload` delegate writes
/// through `StoreClient` directly): this only lists, removes, and clears.
/// Deletion from disk is detected per row at load — `FileManager` stats a
/// few hundred paths in microseconds, so the Deleted badge is always live
/// without a stored flag to go stale.
@MainActor
final class DownloadsStore: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var isLoading = false
    @Published var failure: String?

    /// Retries a failed row by re-fetching its source. Wired by the presenter
    /// to the owning tab's navigation, which routes back through the download
    /// policy and records a fresh row.
    var onRetry: ((URL) -> Void)?

    private let client: StoreClient
    private var loadTask: Task<Void, Never>?

    init(client: StoreClient? = nil) {
        self.client = client ?? .shared
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            // Rows stuck in-progress by a crash, kill, or power loss read as
            // eternally downloading; fail them once per launch before listing.
            await DownloadsCenter.shared.reconcileInterrupted()
            do {
                let data = try await client.downloadHistory()
                var items = DownloadItem.decodeList(data)
                let manager = FileManager.default
                for index in items.indices {
                    items[index].isMissing = !manager.fileExists(
                        atPath: items[index].destinationPath
                    )
                }
                guard !Task.isCancelled else { return }
                self.items = items
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            isLoading = false
        }
    }

    func refresh() {
        load()
    }

    func remove(_ item: DownloadItem) async {
        do {
            try await client.removeDownload(id: item.id)
            load()
        } catch {
            failure = error.localizedDescription
        }
    }

    func clear() async {
        do {
            try await client.clearDownloads()
            load()
        } catch {
            failure = error.localizedDescription
        }
    }

    func retry(_ item: DownloadItem) {
        guard let url = URL(string: item.sourceURL) else { return }
        onRetry?(url)
    }
}
