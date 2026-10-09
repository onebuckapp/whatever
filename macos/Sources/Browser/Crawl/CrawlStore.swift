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

import AppKit
import Combine
import Foundation

/// Headlines for the crawl bar, read straight from the feeds store.
///
/// This is deliberately separate from `FeedReaderStore`: the reader's
/// `articles` reflect whichever feed is selected in the reader card, while the
/// crawl always shows the latest headlines across *every* subscription. The
/// fetch is cache-only (`feedArticles` with an empty feed URL), so the crawl
/// never triggers downloads itself — it just renders what ingestion has
/// already persisted.
@MainActor
final class CrawlStore: ObservableObject {
    /// Ticker-ready headlines, newest first. Empty means the bar hides.
    @Published private(set) var headlines: [CrawlHeadline] = []
    /// Favicons keyed by feed URL, mirrored from the reader store so the
    /// ticker can show site icons without owning image loading itself.
    @Published private(set) var faviconImages: [String: NSImage] = [:]

    private let client: StoreClient
    private var refreshCancellables = Set<AnyCancellable>()
    private var refreshTimer: AnyCancellable?
    private var isLoading = false

    /// `client` defaults to the shared client when nil: spelled this way
    /// rather than `= .shared` so the main-actor-isolated singleton is only
    /// touched from inside the isolated init body.
    init(client: StoreClient? = nil) {
        self.client = client ?? .shared
    }

    /// Starts observing feed refreshes and the periodic fallback. The owning
    /// `CrawlBarController` calls this once; the crawl itself loads on demand
    /// in `reloadIfNeeded`.
    func startObserving() {
        let readerStore = FeedReaderCoordinator.shared.store
        // Favicon arrivals re-render the ticker with icons. The assignment
        // copies the reference; emissions only happen on real changes.
        readerStore.$faviconImages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] images in
                self?.faviconImages = images
            }
            .store(in: &refreshCancellables)
        // The subscription set is the crawl's content: adding the first feed
        // or removing the last one (including Remove everything) must update
        // the bar even when no refresh runs. The `dropFirst` skips the
        // publisher's initial value, which predates any change.
        readerStore.$subscriptions
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.load()
                }
            }
            .store(in: &refreshCancellables)
        // A finished reader refresh may have changed what is persisted, so the
        // next completed pass reloads the crawl. The `dropFirst` skips the
        // publisher's initial value, which predates any refresh.
        readerStore.$isRefreshing
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRefreshing in
                guard !isRefreshing else { return }
                Task { @MainActor in
                    await self?.load()
                }
            }
            .store(in: &refreshCancellables)
        // Fallback for refreshes that happen while no reader is open (automatic
        // background refreshes, other windows). Five minutes matches the
        // coarsest reasonable staleness for a headline strip.
        refreshTimer = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.load()
                }
            }
    }

    func stopObserving() {
        refreshCancellables.removeAll()
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    /// Test seam: sets headlines without the store service, so layout tests
    /// can drive the bar without XPC.
    func replaceHeadlinesForTesting(_ headlines: [CrawlHeadline]) {
        self.headlines = headlines
    }

    /// Reloads headlines from the persisted cache. Failures keep the previous
    /// content: a transient XPC hiccup must not blank a scrolling bar, and a
    /// store with nothing in it simply yields no headlines, which hides the bar.
    /// Concurrent calls collapse into one; settings drags can trigger reloads
    /// faster than the store answers.
    ///
    /// Unread only: the bar is an unread strip, and tapping a headline marks
    /// it read (see `markReadAndDrop`), which is what removes it.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await client.feedArticles(feedURL: "", onlyUnread: true, limit: 200)
            headlines = CrawlContent.headlines(from: FeedArticleSummary.decodeList(data))
            await warmFavicons()
        } catch {
            // Keep showing what was there; an empty store stays empty.
        }
    }

    /// Marks a tapped headline read and drops it from the bar at once.
    ///
    /// The removal is local and immediate, so the tap answers without
    /// waiting for the round trip; persistence and a reconciling reload
    /// follow behind. A failed persist heals on that reload, which refetches
    /// the store truth (unread-only) and brings the item back.
    func markReadAndDrop(_ headline: CrawlHeadline) {
        headlines.removeAll { $0.id == headline.id }
        Task {
            try? await client.setFeedArticleState(
                id: headline.articleID,
                isRead: true,
                isSaved: headline.isSaved
            )
            await load()
        }
    }

    /// Downloads the icons of the shown subscriptions through the reader
    /// store's pipeline (persisted first, then remote), so ticker items can
    /// carry favicons. Headlines publish before warming: icons pop in as
    /// they arrive instead of delaying the strip.
    private func warmFavicons() async {
        let readerStore = FeedReaderCoordinator.shared.store
        var subscriptions = readerStore.subscriptions
        if subscriptions.isEmpty {
            guard let data = try? await client.feedSubscriptions() else { return }
            subscriptions = FeedSubscription.decodeList(data)
        }
        for subscription in subscriptions where readerStore.faviconImages[subscription.feedURL] == nil {
            Task { @MainActor in
                _ = await readerStore.favicon(for: subscription)
            }
        }
    }
}
