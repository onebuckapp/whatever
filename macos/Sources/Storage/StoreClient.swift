import Foundation

/// App-side handle on the `WhateverStore` XPC service.
///
/// One connection, created lazily and shared. The service is on-demand, so the
/// first call pays the launch cost and later ones reuse a live connection; if
/// launchd tears the service down while the app is running, the next call
/// reconnects rather than failing.
///
/// Nothing here blocks. Every method is `async` and the reply arrives on the
/// main queue, so the call sites read as if the store were a plain local object
/// while the disk work happens in another process.
///
/// The service owns the stores outright: boogie holds an exclusive lock on each
/// store path, so the app must never try to open them itself.
@MainActor
final class StoreClient {
    static let shared = StoreClient()

    /// Mach service name: the XPC service bundle's identifier, which is what
    /// launchd registers a bundled service under.
    private static let serviceName = "com.onebuckapps.whatever.store"

    private var connection: NSXPCConnection?

    /// Whether the service answered a `version` call this session.
    private(set) var isReachable = false

    /// Last connection failure, for diagnostics. Nil means the service has
    /// answered at least once.
    private(set) var lastConnectionError: Error?

    private init() {}

    // MARK: Connection

    /// The live proxy, opening a connection if there is not one already.
    private func store() throws -> WhateverStoreProtocol {
        if let proxy = existingProxy() {
            return proxy
        }
        return try connect()
    }

    /// The proxy for an already-open connection, or nil when there is none.
    ///
    /// A connection that has been interrupted or invalidated is dropped by its
    /// handler, so a non-nil `connection` here means one worth using. The error
    /// handler is attached per proxy: it fires when the service dies, which
    /// launchd does on idle eviction, so the next call reconnects rather than
    /// talking to a dead service.
    private func existingProxy() -> WhateverStoreProtocol? {
        guard let connection else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.connection = nil
            self?.lastConnectionError = error
        } as? WhateverStoreProtocol
    }

    private func connect() throws -> WhateverStoreProtocol {
        let connection = NSXPCConnection(serviceName: Self.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: WhateverStoreProtocol.self)
        connection.interruptionHandler = { [weak self] in
            self?.connection = nil
        }
        connection.invalidationHandler = { [weak self] in
            self?.connection = nil
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.lastConnectionError = error
        } as? WhateverStoreProtocol else {
            connection.invalidate()
            throw StoreErrors.unavailable()
        }
        self.connection = connection
        return proxy
    }

    // MARK: Call shapes

    /// A call that returns nothing but a possible error.
    private func perform(
        _ call: (WhateverStoreProtocol, @escaping (NSError?) -> Void) -> Void
    ) async throws {
        let proxy = try store()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            call(proxy) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    /// A call that returns a JSON document.
    private func document(
        _ call: (WhateverStoreProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) async throws -> Data {
        let proxy = try store()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            call(proxy) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: StoreErrors.unavailable())
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: Lifecycle

    /// Asks the service for its version and expected schema version. Also the
    /// cheapest way to find out whether the service is alive.
    func version() async throws -> StoreVersion {
        let proxy = try store()
        let resolved = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StoreVersion, Error>) in
            proxy.version { version, schema, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(
                    returning: StoreVersion(version: version, schemaVersion: schema)
                )
            }
        }
        isReachable = true
        return resolved
    }

    // MARK: Settings

    func settings() async throws -> Data {
        try await document { proxy, done in
            proxy.settingsGet(reply: done)
        }
    }

    func setSettings(_ document: Data) async throws {
        let proxy = try store()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.settingsSet(document) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    func deleteSettings() async throws {
        try await perform { proxy, done in
            proxy.settingsDelete(reply: done)
        }
    }

    // MARK: Bookmarks

    func bookmarks() async throws -> Data {
        try await document { proxy, done in
            proxy.bookmarkList(reply: done)
        }
    }

    func bookmark(id: String) async throws -> Data {
        try await document { proxy, done in
            proxy.bookmarkGet(id, reply: done)
        }
    }

    func setBookmark(id: String, document: Data) async throws {
        try await perform { proxy, done in
            proxy.bookmarkSet(id, document, reply: done)
        }
    }

    func deleteBookmark(id: String) async throws {
        try await perform { proxy, done in
            proxy.bookmarkDelete(id, reply: done)
        }
    }

    func clearBookmarks() async throws {
        try await perform { proxy, done in
            proxy.bookmarksClear(reply: done)
        }
    }

    // MARK: History

    /// Records a visit to `url`.
    ///
    /// `collapseWindow` is a user setting: a revisit of the same URL inside it
    /// updates the existing row rather than adding a near-duplicate. Zero
    /// disables collapsing; the core's default is used when this is nil.
    func recordVisit(
        url: String,
        title: String,
        at date: Date = Date(),
        collapseWindow: TimeInterval? = nil
    ) async throws {
        let visitedAt = Int64(date.timeIntervalSince1970)
        let window = Int64(collapseWindow ?? -1)
        try await perform { proxy, done in
            proxy.historyRecord(url, title, visitedAt, window, reply: done)
        }
    }

    func recentHistory(limit: Int) async throws -> Data {
        try await document { proxy, done in
            proxy.historyRecent(Int32(limit), reply: done)
        }
    }

    /// History for one local day, given as `YYYY-MM-DD`.
    func history(onDay day: String) async throws -> Data {
        try await document { proxy, done in
            proxy.historyByDay(day, reply: done)
        }
    }

    func fuzzySearchHistory(_ query: String, limit: Int) async throws -> Data {
        try await document { proxy, done in
            proxy.historyFuzzySearch(query, Int32(limit), reply: done)
        }
    }

    func deleteHistoryEntry(id: String) async throws {
        try await perform { proxy, done in
            proxy.historyDelete(id, reply: done)
        }
    }

    /// Removes everything older than `date`, returning how many rows went.
    @discardableResult
    func deleteHistory(olderThan date: Date) async throws -> Int {
        let proxy = try store()
        let cutoff = Int64(date.timeIntervalSince1970)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            proxy.historyDeleteBefore(cutoff) { count, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: Int(count))
            }
        }
    }

    func clearHistory() async throws {
        try await perform { proxy, done in
            proxy.historyClear(reply: done)
        }
    }

    // MARK: Sessions

    func session() async throws -> Data {
        try await document { proxy, done in
            proxy.sessionLoad(reply: done)
        }
    }

    func saveSession(_ document: Data) async throws {
        try await perform { proxy, done in
            proxy.sessionSave(document, reply: done)
        }
    }

    func clearSession() async throws {
        try await perform { proxy, done in
            proxy.sessionClear(reply: done)
        }
    }

    // MARK: QR

    /// Renders `text` as a QR symbol's SVG document.
    func qrSVG(
        for text: String,
        ec: Int32 = 2,
        scale: Int32 = 8,
        border: Int32 = 4,
        darkHex: String? = nil,
        lightHex: String? = nil
    ) async throws -> String {
        let proxy = try store()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            proxy.qrSVG(text, ec, scale, border, darkHex, lightHex) { document, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let document else {
                    continuation.resume(throwing: StoreErrors.unavailable())
                    return
                }
                continuation.resume(returning: document)
            }
        }
    }

    // MARK: Filters

    /// Compiles filter-list text into a WebKit content-blocker JSON array.
    func compiledFilters(_ lists: String) async throws -> Data {
        try await document { proxy, done in
            proxy.filterCompile(lists, reply: done)
        }
    }

    /// Counts and fingerprint for filter-list text, without the JSON.
    func filterMeta(_ lists: String, version: String) async throws -> Data {
        try await document { proxy, done in
            proxy.filterMeta(lists, version, reply: done)
        }
    }
}

/// What the service reported about itself.
struct StoreVersion {
    let version: String
    let schemaVersion: Int32
}