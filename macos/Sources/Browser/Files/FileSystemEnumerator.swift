import Foundation

/// Lists one directory's children, batch by batch, off the main thread.
///
/// `FileManager.enumerator` with bulk resource keys is already lazy: one
/// `getattrlistbulk` per batch of names instead of a `stat` per file, so the
/// first rows are ready in milliseconds even where a full materializing walk
/// would take seconds. Batches stream through an `AsyncThrowingStream`, and
/// the UI paints each one as it lands rather than waiting for the walk to
/// finish. Cancellation stops the walk: dismissing the popup mid-listing
/// costs nothing further.
///
/// Non-recursive by construction (`.skipsSubdirectoryDescendants`), so
/// symlink cycles cannot loop the walk: a link is listed as the entry it
/// appears as and never descended into. Unreadable entries are skipped and
/// counted through the error handler instead of failing the listing — one
/// broken symlink must not hide its whole directory. Only a directory that
/// cannot be opened at all fails the stream.
enum FileSystemEnumerator {
    /// One row, fully resolved at enumeration time. Value type, safe to hand
    /// across the background boundary into the UI.
    struct RawEntry: Hashable, Sendable {
        let name: String
        let path: String
        let isDir: Bool
        let size: Int64
        let mtime: Date
        let hidden: Bool
    }

    /// One yielded chunk. `done` marks the walk's end; `capped` says the
    /// entry cap stopped it early rather than the directory running out.
    /// `skipped` accumulates unreadable entries across all batches so far.
    struct Batch: Sendable {
        let entries: [RawEntry]
        let skipped: Int
        let capped: Bool
        let done: Bool
    }

    /// Rows after which a batch is yielded. Small enough to paint early,
    /// large enough that a 30k directory does not publish hundreds of UI
    /// updates.
    private static let batchSize = 200
    /// Ceiling on rows one listing streams. `List` renders lazily, but each
    /// row still costs memory, and past this point the footer says so.
    static let entryCap = 20000

    /// The failure to open `directory` itself: nothing was listed at all.
    struct UnreadableDirectory: LocalizedError, Sendable {
        let directory: String

        var errorDescription: String? {
            "“\(directory)” could not be opened."
        }
    }

    /// Streams `directory`'s children as batches, then finishes. Throws
    /// `UnreadableDirectory` when the directory itself cannot be opened;
    /// per-entry failures only bump `skipped`. `CancellationError` when the
    /// consumer goes away, which is not an error to show.
    static func children(of directory: String) -> AsyncThrowingStream<Batch, Error> {
        children(of: directory, entryCap: entryCap, batchSize: batchSize)
    }

    /// Same walk with explicit bounds, for tests. Production callers use the
    /// default entry point above.
    static func children(
        of directory: String,
        entryCap: Int,
        batchSize: Int
    ) -> AsyncThrowingStream<Batch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try walk(
                        directory: directory,
                        entryCap: entryCap,
                        batchSize: batchSize,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func walk(
        directory: String,
        entryCap: Int,
        batchSize: Int,
        continuation: AsyncThrowingStream<Batch, Error>.Continuation
    ) throws {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
        ]
        // Readability is checked up front rather than inferred from an empty
        // walk: the enumerator reports some failures only through its error
        // handler, which cannot tell a denied directory (an error) from
        // children it skipped past (not an error).
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw UnreadableDirectory(directory: directory)
        }
        var skipped = 0
        // The handler cannot tell a dead child from a dead root: both arrive
        // as a failing URL. Comparing against the root is what keeps a
        // permission-denied directory from reading as an empty one.
        var rootFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { failedURL, _ in
                if failedURL == url {
                    rootFailed = true
                } else {
                    skipped += 1
                }
                return true
            }
        ) else {
            throw UnreadableDirectory(directory: directory)
        }
        var batch: [RawEntry] = []
        batch.reserveCapacity(batchSize)
        var count = 0
        var capped = false
        for case let entryURL as URL in enumerator {
            try Task.checkCancellation()
            guard let entry = RawEntry(url: entryURL, keys: keys) else {
                skipped += 1
                continue
            }
            batch.append(entry)
            count += 1
            if count >= entryCap {
                capped = true
                break
            }
            if batch.count >= batchSize {
                continuation.yield(Batch(entries: batch, skipped: skipped, capped: false, done: false))
                batch = []
                batch.reserveCapacity(batchSize)
            }
        }
        try Task.checkCancellation()
        if rootFailed {
            throw UnreadableDirectory(directory: directory)
        }
        continuation.yield(Batch(entries: batch, skipped: skipped, capped: capped, done: true))
    }
}

private extension FileSystemEnumerator.RawEntry {
    /// Resolves one enumerated URL, or nil when its values are unusable.
    /// `nil` here is what feeds `skipped`: the walk continues past it.
    init?(url: URL, keys: [URLResourceKey]) {
        let name = url.lastPathComponent
        guard !name.isEmpty else { return nil }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Set(keys))
        } catch {
            return nil
        }
        self.name = name
        self.path = url.path
        self.isDir = values.isDirectory ?? false
        self.size = Int64(values.fileSize ?? 0)
        self.mtime = values.contentModificationDate ?? .distantPast
        self.hidden = values.isHidden ?? name.hasPrefix(".")
    }
}
