import Foundation

/// App-side view of the Whatever core, which lives in the `WhateverStore`
/// XPC service.
///
/// The app links no Nim code. `bc_*` is called from inside the service, on that
/// service's own queue, so nothing here touches disk or blocks the main thread.
/// The trade is that every call is `async` now: a round trip through XPC is
/// cheap but not free, and pretending otherwise would hide real latency from the
/// call sites.
enum BrowserCore {
    /// Core version and expected schema version. Also the cheapest reachability
    /// probe, since it touches no store.
    static func version() async throws -> StoreVersion {
        try await StoreClient.shared.version()
    }

    /// Encodes `text` as a Model 2 QR symbol and returns openparser's
    /// standalone SVG document for it.
    ///
    /// `scale` is the pixel size of one module and `border` the quiet zone in
    /// modules. `darkHex` / `lightHex` are CSS colors; pass nil for the core
    /// defaults (black modules, transparent background).
    static func qrSVG(
        for text: String,
        ec: QRErrorCorrection = .quartile,
        scale: Int = 8,
        border: Int = 4,
        darkHex: String? = nil,
        lightHex: String? = nil
    ) async throws -> String {
        try await StoreClient.shared.qrSVG(
            for: text,
            ec: ec.rawValue,
            scale: Int32(scale),
            border: Int32(border),
            darkHex: darkHex,
            lightHex: lightHex
        )
    }
}

/// Error correction level requested from the Nim QR encoder. Raw values mirror
/// the `BC_QR_EC_*` values in `core/include/browsercore.h`.
enum QRErrorCorrection: Int32, CaseIterable {
    case low = 0
    case medium = 1
    case quartile = 2
    case high = 3

    var label: String {
        switch self {
        case .low: "L"
        case .medium: "M"
        case .quartile: "Q"
        case .high: "H"
        }
    }
}

enum BrowserCoreError: Error, LocalizedError {
    case badInput
    case payloadTooLong
    case bufferTooSmall
    case encoderFailed(detail: String)
    case storeUnavailable
    case unknown(code: Int32)

    /// Wraps whatever the service reported, mapping the store's status onto the
    /// vocabulary the QR popup already handled.
    init(underlying error: Error) {
        guard let status = storeStatus(of: error) else {
            self = .encoderFailed(detail: error.localizedDescription)
            return
        }
        switch status {
        case .badInput:
            self = .badInput
        case .payloadTooLong:
            self = .payloadTooLong
        case .bufferTooSmall:
            self = .bufferTooSmall
        case .encoder:
            self = .encoderFailed(detail: error.localizedDescription)
        case .notFound:
            self = .bufferTooSmall
        case .storage, .locked:
            self = .storeUnavailable
        case .ok:
            self = .storeUnavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .badInput:
            "Nothing to encode."
        case .payloadTooLong:
            "This URL is too long to fit in a QR code."
        case .bufferTooSmall:
            "The QR buffer was rejected by the core."
        case let .encoderFailed(detail):
            detail.isEmpty ? "The QR encoder failed." : detail
        case .storeUnavailable:
            "The Whatever store service is not available."
        case let .unknown(code):
            "The QR encoder returned an unexpected status (\(code))."
        }
    }
}