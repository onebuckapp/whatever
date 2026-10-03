import AppKit
import Foundation

/// The core's two-phase buffer protocol, driven from Swift.
///
/// Every variable-length result in `core/include/browsercore.h` is read the
/// same way: ask for the byte count with a NULL buffer, allocate exactly that
/// much, then call again to fill it. The core never allocates memory the caller
/// has to free, so these are the only allocations on the path.
enum CoreBuffer {
    /// A core call that fills a caller-owned buffer. `buffer` is NULL during
    /// the size query.
    typealias Fill = (
        _ buffer: UnsafeMutablePointer<CChar>?,
        _ capacity: Int32,
        _ needed: UnsafeMutablePointer<Int32>?
    ) -> Int32

    /// Runs both phases and returns the filled result, or nil when the call
    /// reported something other than a size query.
    static func read(_ fill: Fill) -> CorePayload? {
        do {
            return try read(fill, rejecting: [])
        } catch {
            return nil
        }
    }

    /// Runs both phases, surfacing `rejected` statuses as thrown errors.
    ///
    /// `rejected` matters because the core validates some arguments *before* it
    /// would ever report a size: `BC_ERR_NOT_FOUND` from `bc_bookmark_get` and
    /// `BC_ERR_BAD_INPUT` from a listing with an empty query are real answers,
    /// not protocol noise, and must not be mistaken for a failed size query.
    static func read(
        _ fill: Fill,
        rejecting rejected: Set<StoreStatus>
    ) throws -> CorePayload? {
        var needed: Int32 = 0
        let probe = fill(nil, 0, &needed)
        guard probe == StoreStatus.bufferTooSmall.rawValue else {
            let value = StoreStatus(rawValue: probe) ?? .storage
            if rejected.contains(value) {
                throw StoreErrors.make(from: probe, message: coreLastError()) as NSError
            }
            return nil
        }
        guard needed > 0 else { return nil }

        var bytes = [CChar](repeating: 0, count: Int(needed))
        var written: Int32 = 0
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            fill(buffer.baseAddress, Int32(buffer.count), &written)
        }
        guard status == StoreStatus.ok.rawValue else {
            throw StoreErrors.make(from: status, message: coreLastError()) as NSError
        }
        return CorePayload(bytes: bytes)
    }
}

/// One result read out of the core, still NUL-terminated.
struct CorePayload {
    let bytes: [CChar]

    /// The document as UTF-8, with the terminator dropped.
    var text: String {
        String(cString: bytes)
    }

    /// The document as JSON data, ready to hand back over XPC.
    var data: Data {
        Data(text.utf8)
    }
}

/// Runs a body with a C string that may be absent, without nesting optional
/// `withCString` closures four deep.
func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
    guard let value else { return try body(nil) }
    return try value.withCString { try body($0) }
}

/// Last message the core recorded, for diagnostics.
///
/// `bc_last_error` always reports the full message length, so a NULL buffer
/// sizes the read and the second call fills it. A message longer than the
/// buffer is truncated, and the returned length is what tells the caller that
/// happened.
func coreLastError() -> String {
    let needed = bc_last_error(nil, 0)
    guard needed > 0 else { return "" }
    var bytes = [CChar](repeating: 0, count: Int(needed))
    let status = bytes.withUnsafeMutableBufferPointer { buffer in
        bc_last_error(buffer.baseAddress, Int32(buffer.count))
    }
    guard status > 0 else { return "" }
    return String(cString: bytes)
}

/// Core calls whose result is not a plain buffer copy.
enum CoreCall {
    /// Renders `text` as a Model 2 QR symbol's standalone SVG document.
    ///
    /// Mirrors the old in-process `BrowserCore.qrSVG`, including its error
    /// mapping, so the QR popup behaves the same through the service.
    static func qrSVG(
        for text: String,
        ec: Int32,
        scale: Int32 = 8,
        border: Int32 = 4,
        dark: String? = nil,
        light: String? = nil
    ) throws -> String {
        var failure: NSError?
        let payload: CorePayload? = text.withCString { page in
            withOptionalCString(dark) { darkHex in
                withOptionalCString(light) { lightHex in
                    let fill: CoreBuffer.Fill = { buffer, capacity, needed in
                        bc_qr_svg(
                            page,
                            ec,
                            scale,
                            border,
                            darkHex,
                            lightHex,
                            buffer,
                            capacity,
                            needed
                        )
                    }
                    // `badInput` is checked by the core before it would report
                    // a size, so it is a real answer rather than phase-one
                    // protocol noise.
                    do {
                        return try CoreBuffer.read(fill, rejecting: [.badInput])
                    } catch {
                        failure = error as NSError
                        return nil
                    }
                }
            }
        }
        if let failure {
            throw CoreQRError(status: Int32(failure.code), message: failure.localizedDescription)
        }
        guard let payload else {
            throw CoreQRError(status: StoreStatus.bufferTooSmall.rawValue, message: coreLastError())
        }
        return payload.text
    }
}

/// Failure from a QR call, mapped to the app's existing error vocabulary.
enum CoreQRError: Error, LocalizedError {
    case badInput
    case tooLong
    case bufferTooSmall
    case encoder(String)
    case storage(String)

    init(status: Int32, message: String) {
        switch status {
        case StoreStatus.badInput.rawValue:
            self = .badInput
        case StoreStatus.bufferTooSmall.rawValue:
            self = .bufferTooSmall
        case StoreStatus.encoder.rawValue:
            self = .encoder(message)
        case StoreStatus.payloadTooLong.rawValue:
            self = .tooLong
        default:
            self = .storage(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .badInput:
            "Nothing to encode."
        case .tooLong:
            "This URL is too long to fit in a QR code."
        case .bufferTooSmall:
            "The QR buffer was rejected by the core."
        case let .encoder(message):
            message.isEmpty ? "The QR encoder failed." : message
        case let .storage(message):
            message.isEmpty ? "The store could not render the code." : message
        }
    }
}
