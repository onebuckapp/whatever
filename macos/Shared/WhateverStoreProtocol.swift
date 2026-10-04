import Foundation

/// XPC surface of the `WhateverStore` service, the one process that owns
/// Whatever's persistent stores.
///
/// The protocol is declared here and compiled into both the app and the
/// service, so both sides always agree: changing it means rebuilding both
/// targets, which is deliberate, since a silent mismatch would surface as a
/// store fault rather than a compile error.
///
/// Everything crosses as JSON `Data` or as a NUL-free Swift value. The store's
/// documents are JSON already, so passing them through unchanged avoids a
/// decode/encode round trip on every settings write and every history page, and
/// it keeps this protocol stable as those documents gain fields.
///
/// Failures arrive as an `NSError` in `StoreError.domain`, carrying the core's
/// status ordinal as its code. Callers should treat them as "the store did not
/// do that" rather than branching on each case, with one exception: `.locked`
/// means another process holds the store and is worth retrying.
@objc public protocol WhateverStoreProtocol {
    // MARK: Lifecycle

    /// Reports the core's version and the schema version it expects. Touches no
    /// store, so it is the cheapest reachability probe.
    func version(reply: @escaping (String, Int32, NSError?) -> Void)

    // MARK: Settings

    func settingsGet(reply: @escaping (Data?, NSError?) -> Void)
    func settingsSet(_ document: Data, reply: @escaping (Int32, NSError?) -> Void)
    func settingsDelete(reply: @escaping (NSError?) -> Void)

    // MARK: Bookmarks

    func bookmarkList(reply: @escaping (Data?, NSError?) -> Void)
    func bookmarkGet(_ id: String, reply: @escaping (Data?, NSError?) -> Void)
    func bookmarkSet(_ id: String, _ document: Data, reply: @escaping (NSError?) -> Void)
    func bookmarkDelete(_ id: String, reply: @escaping (NSError?) -> Void)
    func bookmarksClear(reply: @escaping (NSError?) -> Void)

    // MARK: History

    /// `collapseWindowSecs` is a user setting: a revisit of the same URL inside
    /// the window updates the existing row instead of adding a near-duplicate.
    /// Negative means "use the core's default", zero disables collapsing.
    func historyRecord(
        _ url: String,
        _ title: String,
        _ visitedAt: Int64,
        _ collapseWindowSecs: Int64,
        reply: @escaping (NSError?) -> Void
    )
    func historyRecent(_ limit: Int32, reply: @escaping (Data?, NSError?) -> Void)
    func historyByDay(_ day: String, reply: @escaping (Data?, NSError?) -> Void)
    func historyFuzzySearch(_ query: String, _ limit: Int32, reply: @escaping (Data?, NSError?) -> Void)
    func historyDelete(_ id: String, reply: @escaping (NSError?) -> Void)
    func historyDeleteBefore(_ cutoff: Int64, reply: @escaping (Int32, NSError?) -> Void)
    func historyClear(reply: @escaping (NSError?) -> Void)

    // MARK: Sessions

    func sessionLoad(reply: @escaping (Data?, NSError?) -> Void)
    func sessionSave(_ document: Data, reply: @escaping (NSError?) -> Void)
    func sessionClear(reply: @escaping (NSError?) -> Void)

    // MARK: QR

    /// Renders a Model 2 QR symbol as a standalone SVG document.
    func qrSVG(
        _ text: String,
        _ ec: Int32,
        _ scale: Int32,
        _ border: Int32,
        _ dark: String?,
        _ light: String?,
        reply: @escaping (String?, NSError?) -> Void
    )
}

/// Status ordinals shared with the core, mirroring `core/include/browsercore.h`.
public enum StoreStatus: Int32, Sendable {
    case ok = 0
    case badInput = 1
    case bufferTooSmall = 2
    case storage = 3
    case encoder = 4
    case notFound = 5
    case locked = 6
    /// The payload does not fit the symbol at any error-correction level. The
    /// only code the QR surface adds; it sits above the shared range so it
    /// cannot be confused with the codes below.
    case payloadTooLong = 7

    /// Fallback text, so a caller never has to render an empty error.
    public var message: String {
        switch self {
        case .ok: "OK"
        case .badInput: "The store rejected the request as malformed."
        case .bufferTooSmall: "The store's answer was larger than expected."
        case .storage: "The store could not complete the request."
        case .encoder: "The encoder failed."
        case .notFound: "No such item."
        case .locked: "Another process is using the store."
        case .payloadTooLong: "That will not fit in a QR code."
        }
    }
}

/// Failure reported by the store, carrying the core's status and message.
public struct StoreError: Error, LocalizedError, Sendable {
    /// `NSError` domain the store's failures arrive under, including once they
    /// have crossed XPC.
    public static let domain = "com.onebuckapps.whatever.store"

    public let status: StoreStatus
    public let detail: String?

    public init(status: StoreStatus, detail: String?) {
        self.status = status
        self.detail = detail
    }

    public var errorDescription: String? {
        guard let detail, !detail.isEmpty else { return status.message }
        return detail
    }

    /// Another process holds the store's lock. Worth retrying, unlike a corrupt
    /// or missing database.
    public var isLocked: Bool { status == .locked }
}

/// Reads the status back out of an `NSError` the store produced, whether it
/// arrived from the service or was built in-process.
public func storeStatus(of error: Error) -> StoreStatus? {
    let nsError = error as NSError
    guard nsError.domain == StoreError.domain else { return nil }
    return StoreStatus(rawValue: Int32(nsError.code))
}

/// Builds the `NSError` that crosses XPC. Declared here rather than beside the
/// core bridge because the app needs `unavailable()` too, and the app does not
/// link the core.
public enum StoreErrors {
    /// nil when the call succeeded, an error describing it otherwise.
    public static func check(_ status: Int32, message: String) -> NSError? {
        guard status != StoreStatus.ok.rawValue else { return nil }
        return make(from: status, message: message)
    }

    public static func make(from status: Int32, message: String) -> NSError {
        let value = StoreStatus(rawValue: status) ?? .storage
        let description = message.isEmpty ? value.message : message
        let underlying = StoreError(status: value, detail: description)
        return NSError(
            domain: StoreError.domain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: underlying.errorDescription ?? description,
                // Preserved so a caller can recognise a busy store without
                // parsing the message.
                NSUnderlyingErrorKey: underlying as NSError,
            ]
        )
    }

    /// The service could not be reached. Distinct from a store failure: no work
    /// was attempted, so retrying once a launch completes is reasonable.
    public static func unavailable() -> NSError {
        NSError(
            domain: StoreError.domain,
            code: Int(StoreStatus.storage.rawValue),
            userInfo: [
                NSLocalizedDescriptionKey: "The Whatever store service is not available."
            ]
        )
    }
}