import Foundation
import WebKit

/// Persistent reader state.
///
/// The store owns subscriptions, article listings, read/save state, refresh,
/// and lazy media persistence. Feed bytes and images are downloaded only for
/// explicit subscribe, refresh, and on-screen card actions; discovery alone
/// never reaches this far.
///
/// Private browsing never reaches this far either. Callers must refuse to
/// subscribe or fetch from a private tab, because persistence is the operation
/// being requested.
@MainActor
final class FeedReaderStore: ObservableObject {
    /// Refresh no more often than this without an explicit user request, so
    /// opening the reader does not turn into polling.
    static let automaticRefreshInterval: TimeInterval = 30 * 60

    private var feedSettings: AppSettings.FeedSettings {
        SettingsStore.shared.settings.feeds
    }

    /// User-configured staleness threshold, clamped to a sane range. The
    /// five-minute floor keeps an accidental zero from becoming polling; the
    /// one-day ceiling keeps “automatic” meaningful.
    private var refreshInterval: TimeInterval {
        min(max(feedSettings.refreshIntervalMinutes, 5), 1_440) * 60
    }

    /// Retention requested by settings, clamped to the core's accepted range.
    private var maximumArticles: Int {
        min(max(feedSettings.maximumArticlesPerFeed, 1), 5_000)
    }

    /// Whether opening an article marks it read. Read here so the card and the
    /// settings pane share one source of truth.
    var marksReadOnOpen: Bool {
        feedSettings.markArticlesReadOnOpen
    }

    @Published private(set) var subscriptions: [FeedSubscription] = []
    @Published private(set) var articles: [FeedArticleSummary] = []
    @Published var selectedFeedURL: String?
    @Published private(set) var pageCandidates: [FeedCandidate] = []
    @Published private(set) var pageURL: URL?
    @Published private(set) var pageSiteName: String?
    @Published private(set) var allowsPersistence = true
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var failure: String?
    @Published var thumbnailImages: [Int64: NSImage] = [:]
    @Published var faviconImages: [String: NSImage] = [:]
    @Published private(set) var articleDetails: [Int64: FeedArticleDetail] = [:]

    private let client: StoreClient
    private let fetcher: FeedFetcher
    private var thumbnailTasks: Set<Int64> = []
    private var faviconTasks: Set<String> = []
    private weak var pageWebView: WKWebView?

    init(client: StoreClient = .shared, fetcher: FeedFetcher = .shared) {
        self.client = client
        self.fetcher = fetcher
    }

    /// Prepares one reader session around the current page's candidates.
    ///
    /// Candidates are transient page state, while subscriptions and articles
    /// are persistent reader state. Keeping both here lets the same card offer
    /// “subscribe to this page’s feed” and browse everything already saved.
    func present(
        candidates: [FeedCandidate],
        pageURL: URL?,
        siteName: String?,
        webView: WKWebView?,
        allowsPersistence: Bool
    ) async {
        pageCandidates = candidates
        self.pageURL = pageURL
        pageSiteName = siteName
        pageWebView = webView
        self.allowsPersistence = allowsPersistence
        let initial = candidates.first(where: { candidate in
            subscriptions.contains(where: { $0.feedURL == candidate.url.absoluteString })
        })?.url.absoluteString
        await load(feedURL: initial)
    }

    // MARK: - Loading

    /// Loads subscriptions and the selected feed's first page.
    func load(feedURL: String? = nil, onlyUnread: Bool = false) async {
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            subscriptions = FeedSubscription.decodeList(try await client.feedSubscriptions())
            if let feedURL, subscriptions.contains(where: { $0.feedURL == feedURL }) {
                selectedFeedURL = feedURL
            } else if selectedFeedURL == nil {
                selectedFeedURL = subscriptions.first?.feedURL
            }
            try await loadArticles(onlyUnread: onlyUnread)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Loads one page of the selected feed.
    func loadArticles(feedURL: String? = nil, onlyUnread: Bool = false, limit: Int = 100) async throws {
        let target = feedURL ?? selectedFeedURL ?? ""
        let data = try await client.feedArticles(feedURL: target, onlyUnread: onlyUnread, limit: limit)
        articles = FeedArticleSummary.decodeList(data)
    }

    /// Returns the full article, including bodies and persisted thumbnail bytes.
    func detail(for article: FeedArticleSummary) async -> FeedArticleDetail? {
        if let cached = articleDetails[article.articleID] {
            return cached
        }
        do {
            let detail = try JSONDecoder().decode(
                FeedArticleDetail.self,
                from: try await client.feedArticle(id: article.articleID)
            )
            articleDetails[article.articleID] = detail
            return detail
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    // MARK: - Subscriptions

    /// Subscribes to one advertised feed, fetches it once, and persists its
    /// site icon when the page can supply one.
    @discardableResult
    func subscribe(
        _ candidate: FeedCandidate,
        pageURL: URL,
        siteName: String?,
        webView: WKWebView?,
        allowsPersistence: Bool
    ) async throws -> FeedSubscription {
        guard allowsPersistence else { throw FeedReaderError.privateContext }
        guard feedSettings.isEnabled else { throw FeedReaderError.feedsDisabled }
        try await client.subscribeToFeed(
            feedURL: candidate.url.absoluteString,
            pageURL: pageURL.absoluteString,
            siteName: siteName,
            declaredTitle: candidate.title.isEmpty ? nil : candidate.title,
            declaredType: candidate.type.isEmpty ? nil : candidate.type
        )
        try await refreshFeed(candidate.url.absoluteString, force: true)
        await persistFavicon(feedURL: candidate.url.absoluteString, pageURL: pageURL, webView: webView)
        try await load(feedURL: candidate.url.absoluteString)
        guard let subscription = subscriptions.first(where: { $0.feedURL == candidate.url.absoluteString }) else {
            throw FeedReaderError.subscriptionMissing
        }
        return subscription
    }

    func subscription(for candidate: FeedCandidate) -> FeedSubscription? {
        subscriptions.first(where: { $0.feedURL == candidate.url.absoluteString })
    }

    /// Subscribes to one of the current page's candidates using the page
    /// context captured when the reader opened.
    func subscribeToPageCandidate(_ candidate: FeedCandidate) async {
        guard let pageURL else {
            failure = FeedReaderError.invalidFeedURL.localizedDescription
            return
        }
        do {
            _ = try await subscribe(
                candidate,
                pageURL: pageURL,
                siteName: pageSiteName,
                webView: pageWebView,
                allowsPersistence: allowsPersistence
            )
        } catch {
            failure = error.localizedDescription
        }
    }
    func unsubscribe(_ subscription: FeedSubscription) async {
        do {
            try await client.unsubscribeFromFeed(feedURL: subscription.feedURL)
            faviconImages.removeValue(forKey: subscription.feedURL)
            if selectedFeedURL == subscription.feedURL {
                selectedFeedURL = nil
            }
            try await load()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Removes every subscription and its cached articles.
    ///
    /// Children are removed through the normal unsubscribe path, so foreign-key
    /// order and image caches stay consistent.
    func removeAllSubscriptions() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let subscriptions = FeedSubscription.decodeList(try await client.feedSubscriptions())
            for subscription in subscriptions {
                try await client.unsubscribeFromFeed(feedURL: subscription.feedURL)
            }
            faviconImages.removeAll()
            thumbnailImages.removeAll()
            articleDetails.removeAll()
            selectedFeedURL = nil
            try await load()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Applies the configured per-feed retention limit to every subscription.
    func applyRetention() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let subscriptions = FeedSubscription.decodeList(try await client.feedSubscriptions())
            for subscription in subscriptions {
                try await client.pruneFeed(feedURL: subscription.feedURL, maximumArticles: maximumArticles)
            }
            try await load(feedURL: selectedFeedURL)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Forces a refresh of every subscription.
    func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let subscriptions = FeedSubscription.decodeList(try await client.feedSubscriptions())
            for subscription in subscriptions {
                try await refreshFeed(subscription.feedURL, force: true)
            }
            try await load(feedURL: selectedFeedURL)
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Refresh

    /// Refreshes one subscription, honoring conditional requests and recording
    /// transport outcomes separately from parse outcomes.
    func refresh(_ subscription: FeedSubscription, force: Bool = false) async {
        guard feedSettings.isEnabled else {
            failure = FeedReaderError.feedsDisabled.localizedDescription
            return
        }
        guard let url = URL(string: subscription.feedURL) else { return }
        let lastChecked = Date(timeIntervalSince1970: TimeInterval(subscription.lastCheckedAt))
        if !force {
            guard feedSettings.autoRefreshEnabled else { return }
            guard Date().timeIntervalSince(lastChecked) >= refreshInterval else { return }
        }
        isRefreshing = true
        failure = nil
        defer { isRefreshing = false }
        do {
            try await refreshFeed(subscription.feedURL, force: force)
            try await load(feedURL: selectedFeedURL)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func refreshFeed(_ feedURL: String, force: Bool) async throws {
        guard let url = URL(string: feedURL) else { throw FeedReaderError.invalidFeedURL }
        let subscriptions = FeedSubscription.decodeList(try await client.feedSubscriptions())
        let subscription = subscriptions.first(where: { $0.feedURL == feedURL })
        let download = try await fetcher.fetchFeed(
            from: url,
            etag: subscription?.lastETag.isEmpty == false ? subscription?.lastETag : nil,
            lastModified: subscription?.lastModified.isEmpty == false ? subscription?.lastModified : nil
        )
        switch download.outcome {
        case .notModified:
            try await client.noteFeedFetch(
                feedURL: feedURL,
                status: "not-modified",
                etag: download.etag,
                lastModified: download.lastModified
            )
        case let .modified(data):
            do {
                if feedSettings.strictParsing {
                    _ = try await client.ingestFeedStrictly(feedURL: download.finalURL.absoluteString, payload: data)
                } else {
                    _ = try await client.ingestFeed(feedURL: download.finalURL.absoluteString, payload: data)
                }
                // Retention is applied after ingestion rather than assumed by
                // it, so changing the setting rewrites the cache without
                // re-downloading a feed.
                try await client.pruneFeed(feedURL: feedURL, maximumArticles: maximumArticles)
            } catch {
                // A downloaded but unparseable feed is still a fetch outcome
                // worth recording, so the reader can say “broken feed” rather
                // than “network failed”.
                try? await client.noteFeedFetch(feedURL: feedURL, status: "parse-error", error: error.localizedDescription)
                throw error
            }
        }
        _ = force
    }

    // MARK: - Article state

    func markRead(_ article: FeedArticleSummary, isRead: Bool = true) async {
        await setState(article, isRead: isRead, isSaved: article.isSaved)
    }

    func toggleSaved(_ article: FeedArticleSummary) async {
        await setState(article, isRead: article.isRead, isSaved: !article.isSaved)
    }

    private func setState(_ article: FeedArticleSummary, isRead: Bool, isSaved: Bool) async {
        do {
            try await client.setFeedArticleState(id: article.articleID, isRead: isRead, isSaved: isSaved)
            if let index = articles.firstIndex(where: { $0.articleID == article.articleID }) {
                articles[index].isRead = isRead
                articles[index].isSaved = isSaved
            }
            subscriptions = FeedSubscription.decodeList(try await client.feedSubscriptions())
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Media

    /// Returns a card thumbnail, downloading and persisting it on first use.
    func thumbnail(for article: FeedArticleSummary) async -> NSImage? {
        if let cached = thumbnailImages[article.articleID] {
            return cached
        }
        guard feedSettings.isEnabled else { return nil }
        guard !thumbnailTasks.contains(article.articleID) else { return nil }
        thumbnailTasks.insert(article.articleID)
        defer { thumbnailTasks.remove(article.articleID) }
        do {
            if article.thumbnail.hasBytes {
                let payload = try JSONDecoder().decode(
                    FeedThumbnailPayload.self,
                    from: try await client.feedThumbnail(articleID: article.articleID)
                )
                if let image = FeedImage.make(from: payload.imageBase64) {
                    thumbnailImages[article.articleID] = image
                    return image
                }
            }
            switch feedSettings.thumbnailPolicy {
            case .off:
                return nil
            case .publisherOnly where article.thumbnail.source == "content":
                // Content-derived images stay remote under this policy.
                // Publisher media and enclosures are still eligible.
                return nil
            case .automatic, .publisherOnly:
                break
            }
            guard let remote = URL(string: article.thumbnail.remoteURL) else { return nil }
            let processed = try await fetcher.fetchThumbnail(from: remote)
            try await client.attachFeedThumbnail(
                articleID: article.articleID,
                mime: processed.mime,
                width: processed.width,
                height: processed.height,
                imageBase64: processed.base64
            )
            if let image = FeedImage.make(from: processed.base64) {
                thumbnailImages[article.articleID] = image
                return image
            }
            return nil
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    /// Returns a subscription favicon, downloading and persisting it on first use.
    func favicon(for subscription: FeedSubscription, pageURL: URL? = nil, webView: WKWebView? = nil) async -> NSImage? {
        if let cached = faviconImages[subscription.feedURL] {
            return cached
        }
        guard feedSettings.isEnabled, feedSettings.downloadFavicons else { return nil }
        guard !faviconTasks.contains(subscription.feedURL) else { return nil }
        faviconTasks.insert(subscription.feedURL)
        defer { faviconTasks.remove(subscription.feedURL) }
        do {
            if subscription.hasFavicon {
                let payload = try JSONDecoder().decode(
                    FeedFaviconPayload.self,
                    from: try await client.feedFavicon(feedURL: subscription.feedURL)
                )
                if let image = FeedImage.make(from: payload.imageBase64) {
                    faviconImages[subscription.feedURL] = image
                    return image
                }
            }
            if let remote = URL(string: subscription.faviconRemoteURL) {
                let processed = try await fetcher.fetchFavicon(from: remote)
                try await client.attachFeedFavicon(
                    feedURL: subscription.feedURL,
                    remoteURL: processed.remoteURL?.absoluteString,
                    mime: processed.mime,
                    imageBase64: processed.base64
                )
                if let image = FeedImage.make(from: processed.base64) {
                    faviconImages[subscription.feedURL] = image
                    return image
                }
            }
            guard let pageURL, let webView else { return nil }
            return await persistFavicon(feedURL: subscription.feedURL, pageURL: pageURL, webView: webView)
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    /// Persists the current page's resolved icon for one subscription.
    @discardableResult
    private func persistFavicon(feedURL: String, pageURL: URL, webView: WKWebView?) async -> NSImage? {
        guard feedSettings.isEnabled, feedSettings.downloadFavicons else { return nil }
        guard let webView else { return nil }
        let resolved: (NSImage?, URL?) = await withCheckedContinuation { continuation in
            FaviconLoader.shared.icon(forPageAt: pageURL, in: webView) { image, source in
                continuation.resume(returning: (image, source))
            }
        }
        guard let image = resolved.0 else { return nil }
        do {
            let processed = try fetcher.processFaviconImage(image, remoteURL: resolved.1)
            try await client.attachFeedFavicon(
                feedURL: feedURL,
                remoteURL: processed.remoteURL?.absoluteString,
                mime: processed.mime,
                imageBase64: processed.base64
            )
            let stored = try JSONDecoder().decode(
                FeedFaviconPayload.self,
                from: try await client.feedFavicon(feedURL: feedURL)
            )
            let decoded = FeedImage.make(from: stored.imageBase64)
            if let decoded {
                faviconImages[feedURL] = decoded
            }
            return decoded
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }
}

enum FeedReaderError: Error, LocalizedError, Sendable {
    case privateContext
    case feedsDisabled
    case invalidFeedURL
    case subscriptionMissing

    var errorDescription: String? {
        switch self {
        case .privateContext:
            "Feeds cannot be saved from a private tab."
        case .feedsDisabled:
            "Feeds are turned off in Settings."
        case .invalidFeedURL:
            "That is not a supported feed address."
        case .subscriptionMissing:
            "The subscription was not found after saving it."
        }
    }
}
