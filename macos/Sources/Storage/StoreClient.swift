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
    private static let serviceName = "com.onebuckapp.whatever.store"

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

    // MARK: Feeds

    func subscribeToFeed(
        feedURL: String,
        pageURL: String,
        siteName: String? = nil,
        declaredTitle: String? = nil,
        declaredType: String? = nil,
        subscribedAt: Date = Date()
    ) async throws {
        let stamp = Int64(subscribedAt.timeIntervalSince1970)
        try await perform { proxy, done in
            proxy.feedSubscribe(feedURL, pageURL, siteName, declaredTitle, declaredType, stamp, reply: done)
        }
    }

    func unsubscribeFromFeed(feedURL: String) async throws {
        try await perform { proxy, done in
            proxy.feedUnsubscribe(feedURL, reply: done)
        }
    }

    func feedSubscriptions() async throws -> Data {
        try await document { proxy, done in
            proxy.feedSubscriptions(reply: done)
        }
    }

    func ingestFeed(feedURL: String, fetchedAt: Date = Date(), payload: Data) async throws -> Data {
        let stamp = Int64(fetchedAt.timeIntervalSince1970)
        return try await document { proxy, done in
            proxy.feedIngest(feedURL, stamp, payload, reply: done)
        }
    }

    func ingestFeedStrictly(feedURL: String, fetchedAt: Date = Date(), payload: Data) async throws -> Data {
        let stamp = Int64(fetchedAt.timeIntervalSince1970)
        return try await document { proxy, done in
            proxy.feedIngestStrict(feedURL, stamp, payload, reply: done)
        }
    }

    func pruneFeed(feedURL: String, maximumArticles: Int) async throws {
        try await perform { proxy, done in
            proxy.feedPrune(feedURL, Int32(maximumArticles), reply: done)
        }
    }

    func noteFeedFetch(
        feedURL: String,
        checkedAt: Date = Date(),
        status: String,
        error: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil
    ) async throws {
        let stamp = Int64(checkedAt.timeIntervalSince1970)
        try await perform { proxy, done in
            proxy.feedNoteFetch(feedURL, stamp, status, error, etag, lastModified, reply: done)
        }
    }

    func feedArticles(
        feedURL: String = "",
        onlyUnread: Bool = false,
        limit: Int = 100,
        beforePublishedAt: Date? = nil,
        beforeID: Int64 = 0
    ) async throws -> Data {
        let stamp = Int64(beforePublishedAt?.timeIntervalSince1970 ?? 0)
        return try await document { proxy, done in
            proxy.feedArticles(feedURL, onlyUnread ? 1 : 0, Int32(limit), stamp, beforeID, reply: done)
        }
    }

    func feedArticle(id: Int64) async throws -> Data {
        try await document { proxy, done in
            proxy.feedArticle(id, reply: done)
        }
    }

    func setFeedArticleState(id: Int64, isRead: Bool, isSaved: Bool) async throws {
        try await perform { proxy, done in
            proxy.feedSetArticleState(id, isRead ? 1 : 0, isSaved ? 1 : 0, reply: done)
        }
    }

    func attachFeedThumbnail(
        articleID: Int64,
        mime: String,
        width: Int64,
        height: Int64,
        imageBase64: String
    ) async throws {
        try await perform { proxy, done in
            proxy.feedAttachThumbnail(articleID, mime, width, height, imageBase64, reply: done)
        }
    }

    func feedThumbnail(articleID: Int64) async throws -> Data {
        try await document { proxy, done in
            proxy.feedThumbnail(articleID, reply: done)
        }
    }

    func attachFeedFavicon(
        feedURL: String,
        remoteURL: String? = nil,
        mime: String,
        imageBase64: String
    ) async throws {
        try await perform { proxy, done in
            proxy.feedAttachFavicon(feedURL, remoteURL, mime, imageBase64, reply: done)
        }
    }

    func feedFavicon(feedURL: String) async throws -> Data {
        try await document { proxy, done in
            proxy.feedFavicon(feedURL, reply: done)
        }
    }

    func discoverFeedsFromHTML(pageURL: String, html: String) async throws -> Data {
        try await document { proxy, done in
            proxy.feedDiscoverFromHTML(pageURL, html, reply: done)
        }
    }

    // MARK: Downloads

    /// Starts tracking a download. `bytesExpected` is -1 while the size is
    /// unknown.
    func recordDownload(
        id: String,
        sourceURL: String,
        filename: String,
        destinationPath: String,
        bytesExpected: Int64,
        startedAt: Date = Date()
    ) async throws {
        let stamp = Int64(startedAt.timeIntervalSince1970)
        try await perform { proxy, done in
            proxy.downloadRecord(
                id, sourceURL, filename, destinationPath,
                bytesExpected, stamp, reply: done
            )
        }
    }

    func updateDownload(id: String, bytesReceived: Int64) async throws {
        try await perform { proxy, done in
            proxy.downloadProgress(id, bytesReceived, reply: done)
        }
    }

    func finishDownload(id: String, bytesReceived: Int64, finishedAt: Date = Date()) async throws {
        let stamp = Int64(finishedAt.timeIntervalSince1970)
        try await perform { proxy, done in
            proxy.downloadFinish(id, bytesReceived, stamp, reply: done)
        }
    }

    func failDownload(id: String, error: String?, bytesReceived: Int64, finishedAt: Date = Date()) async throws {
        let stamp = Int64(finishedAt.timeIntervalSince1970)
        try await perform { proxy, done in
            proxy.downloadFail(id, error, bytesReceived, stamp, reply: done)
        }
    }

    func cancelDownload(id: String, finishedAt: Date = Date()) async throws {
        let stamp = Int64(finishedAt.timeIntervalSince1970)
        try await perform { proxy, done in
            proxy.downloadCancel(id, stamp, reply: done)
        }
    }

    func downloadHistory() async throws -> Data {
        try await document { proxy, done in
            proxy.downloadList(reply: done)
        }
    }

    func removeDownload(id: String) async throws {
        try await perform { proxy, done in
            proxy.downloadRemove(id, reply: done)
        }
    }

    func clearDownloads() async throws {
        try await perform { proxy, done in
            proxy.downloadClear(reply: done)
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

    // MARK: Find

    /// Every occurrence of `query` in `text` as byte ranges, as UTF-8 data.
    /// Stateless: nothing is stored, the core only computes over the arguments.
    func findMatches(
        text: String,
        query: String,
        matchCase: Bool,
        wholeWords: Bool,
        limit: Int
    ) async throws -> Data {
        try await document { proxy, done in
            proxy.findMatches(
                text,
                query,
                matchCase ? 1 : 0,
                wholeWords ? 1 : 0,
                Int32(limit),
                reply: done
            )
        }
    }

    // MARK: Navigation

    /// Whether `url` registers in history: true for a page, false for a
    /// click tracker. The caller records first and drops after, so the
    /// check never blocks navigation. Stateless.
    func historyShouldRecord(_ url: String) async throws -> Bool {
        let proxy = try store()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            proxy.historyShouldRecord(url) { answer, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: answer == 1)
            }
        }
    }
}

/// What the service reported about itself.
struct StoreVersion {
    let version: String
    let schemaVersion: Int32
}