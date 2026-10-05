import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Feed, favicon, and thumbnail downloads.
///
/// All network activity for the reader lives here so the store never fetches.
/// Downloads are explicit, bounded, and conditional: discovery alone never
/// touches a feed document, and refreshes reuse ETags rather than
/// re-downloading unchanged feeds.
@MainActor
final class FeedFetcher {
    static let shared = FeedFetcher()

    private static let feedTimeout: TimeInterval = 25
    private static let mediaTimeout: TimeInterval = 20
    private static let maximumFeedBytes = 2 * 1024 * 1024
    private static let maximumSourceImageBytes = 1024 * 1024
    private static let maximumThumbnailPixels = 640
    private static let maximumFaviconPixels = 64
    private static let maximumThumbnailEncodedBytes = 350_000
    private static let maximumFaviconEncodedBytes = 90_000

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Feeds

    /// One conditional feed download.
    struct FeedDocument: Sendable {
        enum Outcome: Sendable {
            case modified(Data)
            case notModified
        }

        let outcome: Outcome
        let finalURL: URL
        let etag: String?
        let lastModified: String?
    }

    /// Downloads a feed document without parsing it. Parsing and persistence
    /// belong to the core; this only enforces transport limits and reports
    /// conditional outcomes.
    func fetchFeed(
        from url: URL,
        etag: String? = nil,
        lastModified: String? = nil
    ) async throws -> FeedDocument {
        let download = try await download(
            from: url,
            accept: "application/rss+xml, application/atom+xml, application/xml, text/xml, application/json, text/html;q=0.8, */*;q=0.1",
            etag: etag,
            lastModified: lastModified,
            timeout: Self.feedTimeout,
            maximumBytes: Self.maximumFeedBytes
        )
        switch download.status {
        case 304:
            return FeedDocument(
                outcome: .notModified,
                finalURL: download.finalURL,
                etag: download.etag ?? etag,
                lastModified: download.lastModified ?? lastModified
            )
        case 200..<300:
            guard !download.data.isEmpty else { throw FeedFetchError.emptyFeed }
            return FeedDocument(
                outcome: .modified(download.data),
                finalURL: download.finalURL,
                etag: download.etag,
                lastModified: download.lastModified
            )
        default:
            throw FeedFetchError.http(status: download.status)
        }
    }

    // MARK: - Images

    /// A downscaled, re-encoded image ready for Base64 persistence.
    struct ProcessedImage: Sendable {
        let remoteURL: URL?
        let mime: String
        let width: Int64
        let height: Int64
        let base64: String
    }

    /// Downloads and normalizes one article thumbnail.
    func fetchThumbnail(from url: URL) async throws -> ProcessedImage {
        try await processImage(
            from: url,
            maximumPixels: Self.maximumThumbnailPixels,
            maximumEncodedBytes: Self.maximumThumbnailEncodedBytes,
            name: "Thumbnail"
        )
    }

    /// Downloads and normalizes one site favicon.
    func fetchFavicon(from url: URL) async throws -> ProcessedImage {
        try await processImage(
            from: url,
            maximumPixels: Self.maximumFaviconPixels,
            maximumEncodedBytes: Self.maximumFaviconEncodedBytes,
            name: "Favicon"
        )
    }

    /// Converts an already-loaded image, such as the page icon WebKit
    /// resolved, into persisted favicon bytes.
    func processFaviconImage(_ image: NSImage, remoteURL: URL?) throws -> ProcessedImage {
        guard let tiff = image.tiffRepresentation,
            let source = CGImageSourceCreateWithData(tiff as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw FeedFetchError.invalidImage
        }
        return try encode(
            cgImage,
            sourceData: tiff,
            remoteURL: remoteURL,
            maximumPixels: Self.maximumFaviconPixels,
            maximumEncodedBytes: Self.maximumFaviconEncodedBytes,
            name: "Favicon"
        )
    }

    // MARK: - Transport

    private struct Download: Sendable {
        let status: Int
        let data: Data
        let finalURL: URL
        let mime: String?
        let etag: String?
        let lastModified: String?
    }

    private func download(
        from url: URL,
        accept: String,
        etag: String?,
        lastModified: String?,
        timeout: TimeInterval,
        maximumBytes: Int
    ) async throws -> Download {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw FeedFetchError.unsupportedURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified, !lastModified.isEmpty {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = response.url ?? Optional(url) else {
            throw FeedFetchError.transport("The server returned an unreadable response.")
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 65_536))
        // The cap is checked while streaming so a hostile `Content-Length`
        // cannot allocate the whole download before the first byte arrives.
        for try await byte in bytes.prefix(maximumBytes + 1) {
            data.append(byte)
            if data.count > maximumBytes {
                throw FeedFetchError.tooLarge(maximumBytes: maximumBytes)
            }
        }
        return Download(
            status: http.statusCode,
            data: data,
            finalURL: finalURL,
            mime: http.mimeType?.lowercased(),
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    // MARK: - Image processing

    private func processImage(
        from url: URL,
        maximumPixels: Int,
        maximumEncodedBytes: Int,
        name: String
    ) async throws -> ProcessedImage {
        let download = try await download(
            from: url,
            accept: "image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8",
            etag: nil,
            lastModified: nil,
            timeout: Self.mediaTimeout,
            maximumBytes: Self.maximumSourceImageBytes
        )
        guard (200..<300).contains(download.status), !download.data.isEmpty else {
            throw FeedFetchError.invalidImage
        }
        guard let source = CGImageSourceCreateWithData(download.data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw FeedFetchError.invalidImage
        }
        return try encode(
            cgImage,
            sourceData: download.data,
            remoteURL: download.finalURL,
            maximumPixels: maximumPixels,
            maximumEncodedBytes: maximumEncodedBytes,
            name: name
        )
    }

    /// Downscales and re-encodes one decoded image. PNG is the only persisted
    /// encoding: it preserves transparency where the source had it, decodes
    /// everywhere SwiftUI needs it, and matches what the core validates.
    private func encode(
        _ image: CGImage,
        sourceData: Data,
        remoteURL: URL?,
        maximumPixels: Int,
        maximumEncodedBytes: Int,
        name: String
    ) throws -> ProcessedImage {
        let scaled = try downscale(image, sourceData: sourceData, maximumPixels: maximumPixels, name: name)
        let representation = NSBitmapImageRep(cgImage: scaled)
        guard let data = representation.representation(using: .png, properties: [:]),
            !data.isEmpty
        else {
            throw FeedFetchError.invalidImage
        }
        guard data.count <= maximumEncodedBytes else {
            throw FeedFetchError.tooLarge(maximumBytes: maximumEncodedBytes)
        }
        return ProcessedImage(
            remoteURL: remoteURL,
            mime: "image/png",
            width: Int64(scaled.width),
            height: Int64(scaled.height),
            base64: data.base64EncodedString()
        )
    }

    /// Caps the longest edge while preserving aspect ratio. Images already
    /// within bounds are kept as-is, so small favicons are not pointlessly
    /// resampled.
    private func downscale(
        _ image: CGImage,
        sourceData: Data,
        maximumPixels: Int,
        name: String
    ) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > 0 else { throw FeedFetchError.invalidImage }
        guard longest > maximumPixels else { return image }
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw FeedFetchError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FeedFetchError.invalidImage
        }
        return scaled
    }
}

enum FeedFetchError: Error, LocalizedError, Sendable {
    case unsupportedURL
    case transport(String)
    case http(status: Int)
    case tooLarge(maximumBytes: Int)
    case emptyFeed
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            "That address is not a supported HTTP(S) URL."
        case let .transport(detail):
            detail
        case let .http(status):
            "The server returned HTTP \(status)."
        case let .tooLarge(maximumBytes):
            "The download exceeded its \(maximumBytes / 1024) KB limit."
        case .emptyFeed:
            "The server returned an empty feed."
        case .invalidImage:
            "The image could not be decoded."
        }
    }
}
