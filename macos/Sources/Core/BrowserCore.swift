import Foundation

/// Error correction level requested from the Nim QR encoder. Raw values
/// mirror `BC_QR_EC_*` in `core/include/browsercore.h`.
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
    case unknown(code: Int32)

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
        case let .unknown(code):
            "The QR encoder returned an unexpected status (\(code))."
        }
    }
}

/// Swift face of the Nim backend (`libbrowsercore.a`).
///
/// Every call is synchronous and main-thread only, matching the contract in
/// `core/include/browsercore.h`. The core never allocates memory we own: it
/// writes into the buffer allocated here.
enum BrowserCore {
    /// Registers the main thread with Nim's runtime. Called once at launch.
    static func initialize() {
        bc_init()
    }

    static var version: String {
        String(cString: bc_version())
    }

    /// Last error message recorded by the core, for diagnostics.
    static var lastErrorMessage: String {
        let needed = bc_last_error(nil, 0)
        guard needed > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: Int(needed) + 1)
        _ = bc_last_error(&buffer, Int32(buffer.count))
        return String(cString: buffer)
    }

    /// Encodes `text` as a Model 2 QR symbol and returns openparser's
    /// standalone SVG document for it.
    ///
    /// `scale` is the pixel size of one module and `border` the quiet zone
    /// in modules. `darkHex` / `lightHex` are CSS colors; pass nil for the
    /// core defaults (black modules, transparent background).
    static func qrSVG(
        for text: String,
        ec: QRErrorCorrection = .quartile,
        scale: Int = 8,
        border: Int = 4,
        darkHex: String? = nil,
        lightHex: String? = nil
    ) throws -> String {
        // Phase one: ask the core how many bytes the document needs.
        var needed: Int32 = 0
        let probe = text.withCString { pointer in
            withNullableCString(darkHex) { dark in
                withNullableCString(lightHex) { light in
                    bc_qr_svg(
                        pointer,
                        ec.rawValue,
                        Int32(scale),
                        Int32(border),
                        dark,
                        light,
                        nil,
                        0,
                        &needed
                    )
                }
            }
        }
        guard probe == 3, needed > 0 else {
            throw error(for: probe)
        }

        // Phase two: fill an exactly-sized caller-owned buffer.
        var document = [CChar](repeating: 0, count: Int(needed))
        var written: Int32 = 0
        let status = text.withCString { pointer in
            withNullableCString(darkHex) { dark in
                withNullableCString(lightHex) { light in
                    document.withUnsafeMutableBufferPointer { buffer in
                        bc_qr_svg(
                            pointer,
                            ec.rawValue,
                            Int32(scale),
                            Int32(border),
                            dark,
                            light,
                            buffer.baseAddress,
                            Int32(buffer.count),
                            &written
                        )
                    }
                }
            }
        }
        guard status == 0 else {
            throw error(for: status)
        }
        return String(cString: document)
    }

    private static func withNullableCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        if let value {
            return value.withCString { body($0) }
        }
        return body(nil)
    }

    private static func error(for status: Int32) -> BrowserCoreError {
        switch status {
        case 1: .badInput
        case 2: .payloadTooLong
        case 3: .bufferTooSmall
        case 4: .encoderFailed(detail: lastErrorMessage)
        default: .unknown(code: status)
        }
    }
}