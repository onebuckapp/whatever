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
import WebKit

/// One intercepted file download: owns its `WKDownload` and records the
/// lifecycle to the store.
///
/// Plain `NSObject`, not main-actor-isolated: WebKit drives the delegate,
/// so every store and badge call hops to the main actor explicitly instead
/// of assuming the callback thread. Owned by `DownloadsCenter` from adoption
/// to terminal state; the download outlives tabs and navigations by design.
final class WebDownload: NSObject {
    /// Stable handle, generated up front so the row, the badge, and the
    /// delegate all reference the same download from its first byte.
    let id: String

    private var download: WKDownload?
    private let sourceURL: URL
    private let suggestedFilename: String
    private let bytesExpected: Int64
    private var lastProgressUpdate = Date.distantPast
    private var terminal = false

    /// Progress writes are XPC round trips, and the delegate can fire dozens
    /// of times per second on a fast link. At most one store write per
    /// interval; the finish call carries the exact final count regardless.
    private static let progressInterval: TimeInterval = 0.25

    init(
        id: String = UUID().uuidString,
        download: WKDownload,
        sourceURL: URL,
        suggestedFilename: String?,
        bytesExpected: Int64
    ) {
        self.id = id
        self.download = download
        self.sourceURL = sourceURL
        if let suggestedFilename, !suggestedFilename.isEmpty {
            self.suggestedFilename = suggestedFilename
        } else {
            let fallback = sourceURL.lastPathComponent
            self.suggestedFilename = fallback.isEmpty ? "download" : fallback
        }
        self.bytesExpected = bytesExpected
        super.init()
        download.delegate = self
    }

    /// Cancels an in-flight transfer. The delegate failure this produces maps
    /// to the cancelled state, never to failed.
    func cancel() {
        download?.cancel()
    }
}

extension WebDownload: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Record on the main actor, but answer WebKit right away: the
        // destination is computable synchronously, and holding the decision
        // for a store round trip would stall the first bytes.
        let destination = DownloadsCenter.destination(for: suggestedFilename)
        let id = id
        let source = sourceURL.absoluteString
        let expected = (response.expectedContentLength >= 0) ? response.expectedContentLength : bytesExpected
        Task { @MainActor in
            try? await StoreClient.shared.recordDownload(
                id: id,
                sourceURL: source,
                filename: destination.lastPathComponent,
                destinationPath: destination.path,
                bytesExpected: expected,
                startedAt: Date()
            )
        }
        completionHandler(destination)
    }

    func download(
        _ download: WKDownload,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) >= Self.progressInterval else { return }
        lastProgressUpdate = now
        let id = id
        Task { @MainActor in
            try? await StoreClient.shared.updateDownload(id: id, bytesReceived: totalBytesWritten)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard markTerminal() else { return }
        let id = id
        Task { @MainActor in
            // A delegate that only reports completion may never have written
            // progress; -1 keeps whatever the store has.
            try? await StoreClient.shared.finishDownload(id: id, bytesReceived: -1)
            DownloadsBadgeCenter.shared.noteFinished(id: id)
            DownloadsCenter.shared.retire(id: id)
        }
        self.download = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard markTerminal() else { return }
        let id = id
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        Task { @MainActor in
            if cancelled {
                try? await StoreClient.shared.cancelDownload(id: id)
            } else {
                try? await StoreClient.shared.failDownload(
                    id: id,
                    error: error.localizedDescription,
                    bytesReceived: -1
                )
            }
            DownloadsCenter.shared.retire(id: id)
        }
        self.download = nil
    }

    /// Claims the terminal transition exactly once. WebKit can deliver a
    /// finish immediately after a failure (or vice versa) on flaky links;
    /// without this the second callback would overwrite the first.
    private func markTerminal() -> Bool {
        if terminal {
            return false
        }
        terminal = true
        return true
    }
}
