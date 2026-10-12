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

    /// Compiles filter-list text (bundled snapshot plus user rules) into a
    /// WebKit content-blocker JSON array, as UTF-8 data.
    static func compiledFilters(_ lists: String) async throws -> Data {
        try await StoreClient.shared.compiledFilters(lists)
    }

    /// Counts and fingerprint for filter-list text, decoded from the core's
    /// meta document.
    static func filterMeta(_ lists: String, version: String) async throws -> FilterMeta {
        let data = try await StoreClient.shared.filterMeta(lists, version: version)
        return try JSONDecoder().decode(FilterMeta.self, from: data)
    }

    /// Every occurrence of `query` in `text`, decoded from the core's find
    /// document. `text` must be exactly what was sent: the ranges are byte
    /// offsets into it.
    static func findMatches(
        text: String,
        query: String,
        matchCase: Bool,
        wholeWords: Bool,
        limit: Int
    ) async throws -> FindMatches {
        let data = try await StoreClient.shared.findMatches(
            text: text,
            query: query,
            matchCase: matchCase,
            wholeWords: wholeWords,
            limit: limit
        )
        return try JSONDecoder().decode(FindMatches.self, from: data)
    }

    /// Whether `url` registers in history: true for a page, false for a
    /// click tracker carrying another link inside itself.
    static func historyShouldRecord(_ url: String) async throws -> Bool {
        try await StoreClient.shared.historyShouldRecord(url)
    }

    /// Points the core at the bundled locale directory. Called once at
    /// launch, before any language is set.
    static func localeInit(moDir: String) async throws {
        try await StoreClient.shared.localeInit(moDir: moDir)
    }

    /// Activates the catalog for a BCP-47 tag. A missing catalog falls back
    /// to English without failing.
    static func setLocale(_ tag: String) async throws {
        try await StoreClient.shared.setLocale(tag)
    }

    /// The active language tag (`ro`, or `en` in English mode).
    static func localeTag() async throws -> String {
        try await StoreClient.shared.localeTag()
    }

    /// Shipped translation tags, sorted, including English.
    static func localeLanguages() async throws -> [String] {
        let data = try await StoreClient.shared.localeLanguages()
        return try JSONDecoder().decode([String].self, from: data)
    }

    /// The active catalog for shell-side caching.
    static func localeTable() async throws -> LocaleTable {
        let data = try await StoreClient.shared.localeTable()
        return try JSONDecoder().decode(LocaleTable.self, from: data)
    }

    /// Translates batch items in order, returning one finished string each.
    /// Plurals and `{name}` formatting resolve core-side.
    static func localeBatch(_ items: [LocaleItem]) async throws -> [String] {
        let document = try JSONEncoder().encode(LocaleBatch(items: items))
        let data = try await StoreClient.shared.localeBatch(document)
        return try JSONDecoder().decode(LocaleBatchResult.self, from: data).texts
    }
}

/// One find-in-page result set, mirrored from the core's `bc_find_matches`
/// document.
///
/// `matches` are half-open byte ranges into the exact text that was sent,
/// front to back. `total` counts every match while `matches` may be capped
/// at the requested limit; `hasMore` says the list was cut. `truncated`
/// says the text itself was cut at the core's cap, so `total` covers only
/// the scanned prefix.
struct FindMatches: Decodable {
    struct Span: Decodable {
        let start: Int
        let stop: Int
    }
    let matches: [Span]
    let total: Int
    let hasMore: Bool
    let truncated: Bool
}

/// Counts and fingerprint describing one filter input, mirrored from the
/// core's `bc_filter_meta` document.
struct FilterMeta: Decodable {
    let ruleCount: Int
    let blockCount: Int
    let cosmeticCount: Int
    let exceptionCount: Int
    let skippedLines: Int
    let inputHashHex: String
    let sourceVersion: String
}

/// The active catalog for shell-side caching, mirrored from the core's
/// `bc_locale_table` document. `strings` maps a msgid — or
/// `msgctxt + "\u{04}" + msgid` — onto its translation. Singular entries
/// only; plural entries resolve through `localeBatch`.
struct LocaleTable: Decodable {
    let lang: String
    let strings: [String: String]
}

/// One batch translation item, mirrored from the core's `bc_locale_batch`
/// shape. `plural` + `n` pick a plural form; `args` fills `{name}`
/// placeholders. Encodes `args` as a string map; numbers stringify
/// core-side, so callers pass them pre-stringified.
///
/// `n` only picks the FORM core-side — the `{n}` placeholder still needs a
/// value, so the init fills `args["n"]` from `n` unless the caller already
/// set it. Without this every plural label rendered its template
/// literally ("{n} visits"), since no call site passed the count twice.
struct LocaleItem: Codable {
    let msgid: String
    let msgctxt: String?
    let plural: String?
    let n: Int?
    let args: [String: String]?

    init(_ msgid: String, ctx: String? = nil, plural: String? = nil, n: Int? = nil, args: [String: String]? = nil) {
        self.msgid = msgid
        self.msgctxt = ctx
        self.plural = plural
        self.n = n
        if let n, args?["n"] == nil {
            var filled = args ?? [:]
            filled["n"] = "\(n)"
            self.args = filled
        } else {
            self.args = args
        }
    }
}

struct LocaleBatch: Codable {
    let items: [LocaleItem]
}

struct LocaleBatchResult: Decodable {
    let texts: [String]
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
        case .wrongPassword:
            // Unreachable for QR: the vault is a different surface. Treated
            // as unavailable rather than inventing a QR meaning for it.
            self = .storeUnavailable
        case .ok:
            self = .storeUnavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .badInput:
            tr("Nothing to encode.", ctx: "Errors")
        case .payloadTooLong:
            tr("This URL is too long to fit in a QR code.", ctx: "Errors")
        case .bufferTooSmall:
            tr("The QR buffer was rejected by the core.", ctx: "Errors")
        case let .encoderFailed(detail):
            detail.isEmpty ? tr("The QR encoder failed.", ctx: "Errors") : detail
        case .storeUnavailable:
            tr("The Whatever store service is not available.", ctx: "Errors")
        case let .unknown(code):
            tr("The QR encoder returned an unexpected status ({code}).", ctx: "Errors", args: ["code": "\(code)"])
        }
    }
}