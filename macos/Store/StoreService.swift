import AppKit
import Foundation

/// Serves the store's XPC interface and owns the one queue every core call
/// goes through.
///
/// The core's exports share module-level state (the error string and the store
/// handles), so they need one caller thread at a time. XPC delivers an exported
/// object's messages on a queue private to each *connection*, so two
/// connections would be two threads; funnelling them all onto one queue is what
/// makes the core see one caller at a time regardless of how many the app opens.
///
/// That queue also has to be told about Nim before use. Nim's allocator keeps
/// per-thread state in thread-local storage that only exists on a thread that
/// has registered itself, and an export reached from an unregistered thread does
/// not fail cleanly: it faults inside `rawAlloc` (EXC_BAD_ACCESS at a small
/// offset from nil) and takes the whole service down, along with the store
/// handles it was holding. `bc_init` covers the main thread; `serve` covers
/// everything that reaches the core queue.
///
/// One store, one owner: boogie holds an exclusive lock on the store path for
/// its whole lifetime, so this process must be the only one opening them. If a
/// second instance ever appears, the open fails with a lock error rather than
/// blocking.
final class StoreService: NSObject, NSXPCListenerDelegate {
    /// Where every core call runs, so the core never sees two callers at once
    /// and disk work stays off the service's main thread.
    private static let coreQueue = DispatchQueue(label: "com.onebuckapps.whatever.store")
    /// Mach service name the app connects to. Kept in step with
    /// `StoreClient.serviceName` and the service bundle identifier.
    static let serviceName = "com.onebuckapps.whatever.store"
    private var listener: NSXPCListener?
    /// Live app connections. The core's stores stay open while any exist.
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    /// The one service instance, kept alive for the life of the process.
    ///
    /// This has to be a static, not a local in `main()`. The listener is
    /// released with its delegate, so a service that nothing else retains
    /// finishes `main()`, gets deallocated, and takes the listener down with
    /// it: launchd then reports the service as inactive and terminates the
    /// process, with no crash and nothing in the log to explain it.
    private static let instance = StoreService()

    /// The whole service, in the order its parts have to come up.
    static func main() {
        instance.start()
        instance.listen()
    }

    /// Registers the main thread with Nim's runtime. Must happen before any
    /// other call, and it is what makes the main queue a legal place to make
    /// one. Idempotent.
    private func start() {
        bc_init()
    }

    private func listen() {
        // `NSXPCListener(machServiceName:)`, not `NSXPCListener.service()`.
        //
        // An embedded service declared `ServiceType = Application` is started by
        // launchd but not registered in its service database, so `.service()`
        // comes back with no name at all — it describes as `service: (null)`
        // — and `resume()` then takes the process down before a single request
        // arrives. Naming the Mach service here registers it in the bootstrap,
        // which is what lets the app's `NSXPCConnection(serviceName:)` find it.
        // The label has to match both that call and the bundle identifier.
        let listener = NSXPCListener(machServiceName: Self.serviceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    // MARK: NSXPCListenerDelegate

    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let handler = StoreServiceHandler(queue: Self.coreQueue)
        connection.exportedInterface = NSXPCInterface(with: WhateverStoreProtocol.self)
        connection.exportedObject = handler
        // Keyed by identifier rather than by the connection itself: the handler
        // takes no arguments, and holding the connection here would keep it
        // alive past its own invalidation.
        let identifier = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in
            self?.connectionDidInvalidate(identifier)
        }
        connection.resume()
        connections[identifier] = connection
        return true
    }

    /// Drops a connection, and tries to flush once the app has none left.
    ///
    /// Best effort, and deliberately not the durability story. launchd
    /// terminates an on-demand Application service as soon as its last client
    /// goes away, which it does in parallel with this handler: measured, the
    /// process is killed part-way through `bc_shutdown`, so the checkpoint never
    /// completes. Anything still only in the WAL when that happens is lost, and
    /// no flush-on-exit can fix it.
    ///
    /// The actual guarantee is in storage/database.nim, where every store
    /// flushes its WAL on each write. That is cheap here — a browser writes a
    /// handful of rows per navigation — and it means durability never depends on
    /// this process getting to run any shutdown code at all. What is left here
    /// is a cheap checkpoint on the paths that do get to finish.
    ///
    /// The invalidation handler arrives on the connection's own queue, so the
    /// bookkeeping and the flush hop to the core queue along with everything
    /// else. Reopening is free: the next call after a flush reopens the stores.
    private func connectionDidInvalidate(_ identifier: ObjectIdentifier) {
        Self.coreQueue.async { [weak self] in
            bc_register_thread()
            guard let self else { return }
            connections.removeValue(forKey: identifier)
            if connections.isEmpty {
                bc_shutdown()
            }
        }
    }
}

/// Implements the exported object. Every method is a thin adapter: hop onto
/// the core queue, unpack the arguments, make one core call, and translate
/// the status ordinal into either a value or an `NSError` carrying the core's
/// message.
final class StoreServiceHandler: NSObject, WhateverStoreProtocol {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Runs `body` on the core queue, so the core never sees two callers at
    /// once and no disk work happens on the service's main thread.
    ///
    /// The reply block is invoked from that queue too, which XPC allows and
    /// which keeps the core call and its reply together.
    ///
    /// `bc_register_thread` first, because this queue is GCD: a serial queue
    /// still makes no promise about which thread runs a given block, and an
    /// unregistered thread does not get an error back from the core, it faults
    /// inside Nim's allocator. After the first call on a thread this is a
    /// thread-local read.
    private func serve(_ reply: @escaping () -> Void) {
        queue.async {
            bc_register_thread()
            reply()
        }
    }

    // MARK: Lifecycle

    func version(reply: @escaping (String, Int32, NSError?) -> Void) {
        serve {
            let schema = bc_core_schema_version()
            guard schema > 0 else {
                reply("", 0, StoreErrors.make(from: schema, message: coreLastError()))
                return
            }
            reply(String(cString: bc_version()), schema, nil)
        }
    }

    // MARK: Settings

    func settingsGet(reply: @escaping (Data?, NSError?) -> Void) {
        serve {
            guard let payload = CoreBuffer.read({ buffer, capacity, needed in
                bc_settings_get(buffer, capacity, needed)
            }) else {
                reply(nil, StoreErrors.make(from: StoreStatus.storage.rawValue, message: coreLastError()))
                return
            }
            reply(payload.data, nil)
        }
    }

    func settingsSet(_ document: Data, reply: @escaping (Int32, NSError?) -> Void) {
        serve {
            var written: Int32 = 0
            let status = document.withUnsafeBytes { raw in
                bc_settings_set(raw.bindMemory(to: CChar.self).baseAddress, &written)
            }
            guard status == StoreStatus.ok.rawValue else {
                reply(0, StoreErrors.make(from: status, message: coreLastError()))
                return
            }
            reply(written, nil)
        }
    }

    func settingsDelete(reply: @escaping (NSError?) -> Void) {
        serve {
            reply(StoreErrors.check(bc_settings_delete(), message: coreLastError()))
        }
    }

    // MARK: Bookmarks

    func bookmarkList(reply: @escaping (Data?, NSError?) -> Void) {
        serve {
            guard let payload = CoreBuffer.read({ buffer, capacity, needed in
                bc_bookmark_list(buffer, capacity, needed)
            }) else {
                reply(nil, StoreErrors.make(from: StoreStatus.storage.rawValue, message: coreLastError()))
                return
            }
            reply(payload.data, nil)
        }
    }

    func bookmarkGet(_ id: String, reply: @escaping (Data?, NSError?) -> Void) {
        serve {
            // `notFound` is a real answer, and the core checks it before it
            // would report a size, so it has to survive phase one.
            let payload: CorePayload?
            do {
                payload = try id.withCString { pointer in
                    try CoreBuffer.read({ buffer, capacity, needed in
                        bc_bookmark_get(pointer, buffer, capacity, needed)
                    }, rejecting: [.notFound])
                }
            } catch {
                reply(nil, error as NSError)
                return
            }
            guard let payload else {
                reply(nil, StoreErrors.make(from: StoreStatus.storage.rawValue, message: coreLastError()))
                return
            }
            reply(payload.data, nil)
        }
    }

    func bookmarkSet(_ id: String, _ document: Data, reply: @escaping (NSError?) -> Void) {
        serve {
            let status = id.withCString { key in
                document.withUnsafeBytes { raw in
                    bc_bookmark_set(key, raw.bindMemory(to: CChar.self).baseAddress)
                }
            }
            reply(StoreErrors.check(status, message: coreLastError()))
        }
    }

    func bookmarkDelete(_ id: String, reply: @escaping (NSError?) -> Void) {
        serve {
            let status = id.withCString { bc_bookmark_delete($0) }
            reply(StoreErrors.check(status, message: coreLastError()))
        }
    }

    func bookmarksClear(reply: @escaping (NSError?) -> Void) {
        serve {
            reply(StoreErrors.check(bc_bookmarks_clear(), message: coreLastError()))
        }
    }

    // MARK: History

    func historyRecord(
        _ url: String,
        _ title: String,
        _ visitedAt: Int64,
        _ collapseWindowSecs: Int64,
        reply: @escaping (NSError?) -> Void
    ) {
        serve {
            let status = url.withCString { pageURL in
                title.withCString { pageTitle in
                    bc_history_record(pageURL, pageTitle, visitedAt, collapseWindowSecs)
                }
            }
        reply(StoreErrors.check(status, message: coreLastError()))
        }
    }

    func historyRecent(_ limit: Int32, reply: @escaping (Data?, NSError?) -> Void) {
        serve {
            guard let payload = CoreBuffer.read({ buffer, capacity, needed in
                bc_history_recent(limit, buffer, capacity, needed)
            }) else {
                reply(nil, StoreErrors.make(from: StoreStatus.storage.rawValue, message: coreLastError()))
                return
            }
            reply(payload.data, nil)
        }
    }

    func historyByDay(_ day: String, reply: @escaping (Data?, NSError?) -> Void) {
        serve {
            let payload: CorePayload?
            do {
                payload = try day.withCString { pointer in
                    try CoreBuffer.read({ buffer, capacity, needed in
                        bc_history_by_day(pointer, buffer, capacity, needed)
                    }, rejecting: [.badInput])
                }
            } catch {
                reply(nil, error as NSError)
                return
            }
            guard let payload else {
                reply(nil, StoreErrors.make(from: StoreStatus.storage.rawValue, message: coreLastError()))
                return
            }
            reply(payload.data, nil)
        }
    }

    func historyFuzzySearch(
        _ query: String,
        _ limit: Int32,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        serve {
            let payload: CorePayload?
            do {
                payload = try query.withCString { pointer in
                    try CoreBuffer.read({ buffer, capacity, needed in
                        bc_history_fuzzy_search(pointer, limit, buffer, capacity, needed)
                    }, rejecting: [.badInput])
                }
            } catch {
                reply(nil, error as NSError)
                return
            }
            guard let payload else {
                reply(nil, StoreErrors.make(from: StoreStatus.storage.rawValue, message: coreLastError()))
                return
            }
            reply(payload.data, nil)
        }
    }

    func historyDelete(_ id: String, reply: @escaping (NSError?) -> Void) {
        serve {
            let status = id.withCString { bc_history_delete($0) }
            reply(StoreErrors.check(status, message: coreLastError()))
        }
    }

    func historyDeleteBefore(_ cutoff: Int64, reply: @escaping (Int32, NSError?) -> Void) {
        serve {
            var removed: Int32 = 0
            let status = bc_history_delete_before(cutoff, &removed)
            guard status == StoreStatus.ok.rawValue else {
                reply(0, StoreErrors.make(from: status, message: coreLastError()))
                return
            }
            reply(removed, nil)
        }
    }

    func historyClear(reply: @escaping (NSError?) -> Void) {
        serve {
            reply(StoreErrors.check(bc_history_clear(), message: coreLastError()))
        }
    }

    // MARK: Sessions

    func sessionLoad(reply: @escaping (Data?, NSError?) -> Void) {
        serve {
            guard let payload = CoreBuffer.read({ buffer, capacity, needed in
                bc_session_load(buffer, capacity, needed)
            }) else {
                reply(nil, StoreErrors.make(from: StoreStatus.storage.rawValue, message: coreLastError()))
                return
            }
            reply(payload.data, nil)
        }
    }

    func sessionSave(_ document: Data, reply: @escaping (NSError?) -> Void) {
        serve {
            let status = document.withUnsafeBytes { raw in
                bc_session_save(raw.bindMemory(to: CChar.self).baseAddress)
            }
            reply(StoreErrors.check(status, message: coreLastError()))
        }
    }

    func sessionClear(reply: @escaping (NSError?) -> Void) {
        serve {
            reply(StoreErrors.check(bc_session_clear(), message: coreLastError()))
        }
    }

    // MARK: QR

    func qrSVG(
        _ text: String,
        _ ec: Int32,
        _ scale: Int32,
        _ border: Int32,
        _ dark: String?,
        _ light: String?,
        reply: @escaping (String?, NSError?) -> Void
    ) {
        serve {
            do {
                let document = try CoreCall.qrSVG(
                    for: text,
                    ec: ec,
                    scale: scale,
                    border: border,
                    dark: dark,
                    light: light
                )
                reply(document, nil)
            } catch {
                reply(nil, error as NSError)
            }
        }
    }
}