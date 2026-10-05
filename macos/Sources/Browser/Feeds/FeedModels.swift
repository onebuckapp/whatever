import AppKit
import Foundation

/// Feed documents advertised by the current page are produced by
/// `FeedDiscovery`; everything below is the persisted reader shape returned by
/// the feeds store.
enum FeedFormat: String, Decodable, Hashable, Sendable {
    case rss
    case atom
    case unknown
}

/// One persisted subscription plus live counts.
struct FeedSubscription: Identifiable, Hashable, Decodable, Sendable {
    var id: String { feedURL }
    let feedURL: String
    let pageURL: String
    let siteHost: String
    let siteName: String
    let feedFormat: FeedFormat
    let feedTitle: String
    let declaredTitle: String
    let declaredType: String
    let faviconRemoteURL: String
    let faviconMime: String
    let hasFavicon: Bool
    let subscribedAt: Int64
    let lastCheckedAt: Int64
    let lastETag: String
    let lastModified: String
    let lastStatus: String
    let lastError: String
    let autoRefreshEnabled: Bool
    let articleCount: Int
    let unreadCount: Int

    private enum CodingKeys: String, CodingKey {
        case feedURL, pageURL, siteHost, siteName, feedFormat, feedTitle
        case declaredTitle, declaredType, faviconRemoteURL, faviconMime
        case hasFavicon, subscribedAt, lastCheckedAt, lastETag, lastModified
        case lastStatus, lastError, autoRefreshEnabled, articleCount, unreadCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feedURL = try container.decode(String.self, forKey: .feedURL)
        pageURL = (try? container.decode(String.self, forKey: .pageURL)) ?? ""
        siteHost = (try? container.decode(String.self, forKey: .siteHost)) ?? ""
        siteName = (try? container.decode(String.self, forKey: .siteName)) ?? ""
        feedFormat = (try? container.decode(FeedFormat.self, forKey: .feedFormat)) ?? .unknown
        feedTitle = (try? container.decode(String.self, forKey: .feedTitle)) ?? ""
        declaredTitle = (try? container.decode(String.self, forKey: .declaredTitle)) ?? ""
        declaredType = (try? container.decode(String.self, forKey: .declaredType)) ?? ""
        faviconRemoteURL = (try? container.decode(String.self, forKey: .faviconRemoteURL)) ?? ""
        faviconMime = (try? container.decode(String.self, forKey: .faviconMime)) ?? ""
        hasFavicon = (try? container.decode(Bool.self, forKey: .hasFavicon)) ?? false
        subscribedAt = (try? container.decode(Int64.self, forKey: .subscribedAt)) ?? 0
        lastCheckedAt = (try? container.decode(Int64.self, forKey: .lastCheckedAt)) ?? 0
        lastETag = (try? container.decode(String.self, forKey: .lastETag)) ?? ""
        lastModified = (try? container.decode(String.self, forKey: .lastModified)) ?? ""
        lastStatus = (try? container.decode(String.self, forKey: .lastStatus)) ?? ""
        lastError = (try? container.decode(String.self, forKey: .lastError)) ?? ""
        autoRefreshEnabled = (try? container.decode(Bool.self, forKey: .autoRefreshEnabled)) ?? true
        articleCount = (try? container.decode(Int.self, forKey: .articleCount)) ?? 0
        unreadCount = (try? container.decode(Int.self, forKey: .unreadCount)) ?? 0
    }

    static func decodeList(_ data: Data) -> [FeedSubscription] {
        (try? JSONDecoder().decode([Failable].self, from: data))?.compactMap(\.value) ?? []
    }

    private struct Failable: Decodable {
        let value: FeedSubscription?
        init(from decoder: Decoder) throws {
            value = try? FeedSubscription(from: decoder)
        }
    }
}

/// Thumbnail metadata carried by article listings. Bytes are intentionally
/// absent here; the card asks for them only when it is on screen.
struct FeedThumbnail: Hashable, Decodable, Sendable {
    let remoteURL: String
    let mime: String
    let width: Int64
    let height: Int64
    let source: String
    let hasBytes: Bool

    init(remoteURL: String, mime: String, width: Int64, height: Int64, source: String, hasBytes: Bool) {
        self.remoteURL = remoteURL
        self.mime = mime
        self.width = width
        self.height = height
        self.source = source
        self.hasBytes = hasBytes
    }

    private enum CodingKeys: String, CodingKey {
        case remoteURL, mime, width, height, source, hasBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteURL = (try? container.decode(String.self, forKey: .remoteURL)) ?? ""
        mime = (try? container.decode(String.self, forKey: .mime)) ?? ""
        width = (try? container.decode(Int64.self, forKey: .width)) ?? 0
        height = (try? container.decode(Int64.self, forKey: .height)) ?? 0
        source = (try? container.decode(String.self, forKey: .source)) ?? ""
        hasBytes = (try? container.decode(Bool.self, forKey: .hasBytes)) ?? false
    }
}

/// One article row as the two-up grid needs it.
struct FeedArticleSummary: Identifiable, Hashable, Decodable, Sendable {
    var id: Int64 { articleID }
    let articleID: Int64
    let feedURL: String
    let guid: String
    let url: String
    let title: String
    let authors: [String]
    let publishedAt: Int64
    let updatedAt: Int64
    let publishedRaw: String
    let fetchedAt: Int64
    let summary: String
    let summaryHTML: String
    let hasContent: Bool
    let thumbnail: FeedThumbnail
    let siteName: String
    let siteHost: String
    let feedTitle: String
    let hasFavicon: Bool
    var isRead: Bool
    var isSaved: Bool

    private enum CodingKeys: String, CodingKey {
        case articleID = "id"
        case feedURL, guid, url, title, authors, publishedAt, updatedAt
        case publishedRaw, fetchedAt, summary, summaryHTML, hasContent, thumbnail
        case siteName, siteHost, feedTitle, hasFavicon, isRead, isSaved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        articleID = try container.decode(Int64.self, forKey: .articleID)
        feedURL = (try? container.decode(String.self, forKey: .feedURL)) ?? ""
        guid = (try? container.decode(String.self, forKey: .guid)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        authors = (try? container.decode([String].self, forKey: .authors)) ?? []
        publishedAt = (try? container.decode(Int64.self, forKey: .publishedAt)) ?? 0
        updatedAt = (try? container.decode(Int64.self, forKey: .updatedAt)) ?? 0
        publishedRaw = (try? container.decode(String.self, forKey: .publishedRaw)) ?? ""
        fetchedAt = (try? container.decode(Int64.self, forKey: .fetchedAt)) ?? 0
        summary = (try? container.decode(String.self, forKey: .summary)) ?? ""
        summaryHTML = (try? container.decode(String.self, forKey: .summaryHTML)) ?? ""
        hasContent = (try? container.decode(Bool.self, forKey: .hasContent)) ?? false
        thumbnail = (try? container.decode(FeedThumbnail.self, forKey: .thumbnail))
            ?? FeedThumbnail(remoteURL: "", mime: "", width: 0, height: 0, source: "", hasBytes: false)
        siteName = (try? container.decode(String.self, forKey: .siteName)) ?? ""
        siteHost = (try? container.decode(String.self, forKey: .siteHost)) ?? ""
        feedTitle = (try? container.decode(String.self, forKey: .feedTitle)) ?? ""
        hasFavicon = (try? container.decode(Bool.self, forKey: .hasFavicon)) ?? false
        isRead = (try? container.decode(Bool.self, forKey: .isRead)) ?? false
        isSaved = (try? container.decode(Bool.self, forKey: .isSaved)) ?? false
    }

    static func decodeList(_ data: Data) -> [FeedArticleSummary] {
        (try? JSONDecoder().decode([Failable].self, from: data))?.compactMap(\.value) ?? []
    }

    private struct Failable: Decodable {
        let value: FeedArticleSummary?
        init(from decoder: Decoder) throws {
            value = try? FeedArticleSummary(from: decoder)
        }
    }

    var displayTitle: String {
        title.isEmpty ? url : title
    }

    var displaySite: String {
        if !siteName.isEmpty { return siteName }
        if !siteHost.isEmpty { return siteHost }
        return feedTitle
    }

    var publishedDate: Date? {
        publishedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(publishedAt)) : nil
    }
}

/// The full article, including bodies and persisted thumbnail bytes.
struct FeedArticleDetail: Decodable, Sendable {
    let summary: FeedArticleSummary
    let content: String
    let contentHTML: String
    let thumbnailImageBase64: String

    private enum CodingKeys: String, CodingKey {
        case content, contentHTML, thumbnailImageBase64
    }

    init(from decoder: Decoder) throws {
        summary = try FeedArticleSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = (try? container.decode(String.self, forKey: .content)) ?? ""
        contentHTML = (try? container.decode(String.self, forKey: .contentHTML)) ?? ""
        thumbnailImageBase64 = (try? container.decode(String.self, forKey: .thumbnailImageBase64)) ?? ""
    }
}

/// What one successful ingestion stored.
struct FeedIngestReport: Decodable, Sendable {
    let feedURL: String
    let format: FeedFormat
    let title: String
    let siteName: String
    let siteHost: String
    let stored: Int
    let updated: Int
    let articles: Int
}

/// Persisted thumbnail bytes for one article.
struct FeedThumbnailPayload: Decodable, Sendable {
    let remoteURL: String
    let mime: String
    let width: Int64
    let height: Int64
    let source: String
    let hasBytes: Bool
    let imageBase64: String
}

/// Persisted favicon bytes for one subscription.
struct FeedFaviconPayload: Decodable, Sendable {
    let feedURL: String
    let remoteURL: String
    let mime: String
    let imageBase64: String
}

/// Base64 bytes from the feeds store as an image, or nil when absent or
/// undecodable. A single malformed image must cost that image, not the card.
enum FeedImage {
    static func make(from base64: String) -> NSImage? {
        let cleaned = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
            let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters),
            !data.isEmpty,
            let image = NSImage(data: data)
        else {
            return nil
        }
        return image
    }
}

/// Short relative timestamps for cards, falling back to nothing rather than a
/// misleading absolute date when the publisher supplied no usable time.
enum FeedTimestamp {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func text(for unixSeconds: Int64, now: Date = Date()) -> String {
        guard unixSeconds > 0 else { return "" }
        return relative.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(unixSeconds)),
            relativeTo: now
        )
    }
}
