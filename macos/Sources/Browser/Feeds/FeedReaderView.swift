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
import SwiftUI

/// The reader surface: subscriptions across the top and native article cards
/// below. Cards stay two-across while the panel has room for two readable
/// cards, then collapse to one column on narrow windows.
struct FeedReaderView: View {
    @ObservedObject private var coordinator = FeedReaderCoordinator.shared
    @State private var selectedArticleID: Int64?
    @State private var detail: FeedArticleDetail?
    @State private var isLoadingDetail = false
    @State private var onlyUnread = false

    private var store: FeedReaderStore { coordinator.store }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let selected = selectedArticle {
                detailView(for: selected)
            } else {
                articleGrid
            }
            if let failure = store.failure {
                Divider()
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 920, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var selectedArticle: FeedArticleSummary? {
        guard let selectedArticleID else { return nil }
        return store.articles.first(where: { $0.articleID == selectedArticleID })
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Feeds")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                if let selected = selectedSubscription {
                    Toggle("Unread only", isOn: $onlyUnread)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .onChange(of: onlyUnread) {
                            Task { try? await store.loadArticles(feedURL: selected.feedURL, onlyUnread: onlyUnread) }
                        }
                    Button {
                        Task { await store.refresh(selected) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(store.isRefreshing)
                    Button(role: .destructive) {
                        Task { await store.unsubscribe(selected) }
                    } label: {
                        Label("Unsubscribe", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
            if store.subscriptions.isEmpty {
                Text("No subscriptions yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Picker("Feed", selection: Binding(
                    get: { store.selectedFeedURL ?? "" },
                    set: { value in
                        store.selectedFeedURL = value.isEmpty ? nil : value
                        Task { try? await store.loadArticles(feedURL: value) }
                    }
                )) {
                    ForEach(store.subscriptions) { subscription in
                        Text("\(subscription.displayName) (\(subscription.unreadCount))")
                            .tag(subscription.feedURL)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 420, alignment: .leading)
            }
            if !store.pageCandidates.isEmpty {
                pageCandidates
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var selectedSubscription: FeedSubscription? {
        guard let selected = store.selectedFeedURL else { return store.subscriptions.first }
        return store.subscriptions.first(where: { $0.feedURL == selected })
    }

    private var pageCandidates: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.allowsPersistence ? "This page offers:" : "This page offers feeds, but private tabs cannot save them.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(store.pageCandidates, id: \.url) { candidate in
                HStack {
                    Text(candidate.title.isEmpty ? candidate.url.absoluteString : candidate.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let existing = store.subscription(for: candidate) {
                        Button("Open") {
                            store.selectedFeedURL = existing.feedURL
                            Task { try? await store.loadArticles(feedURL: existing.feedURL) }
                        }
                        .controlSize(.small)
                    } else {
                        Button("Subscribe") {
                            Task { await store.subscribeToPageCandidate(candidate) }
                        }
                        .controlSize(.small)
                        .disabled(!store.allowsPersistence)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Articles

    private var articleGrid: some View {
        Group {
            if store.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.articles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "newspaper")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(store.subscriptions.isEmpty ? "Subscribe to a feed to start reading." : "No articles match this view.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 340, maximum: 460), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        ForEach(store.articles) { article in
                            FeedCardLoader(article: article) { thumbnail, favicon in
                                FeedArticleCard(
                                    article: article,
                                    favicon: favicon,
                                    thumbnail: thumbnail,
                                    onOpen: { open(article) },
                                    onToggleRead: {
                                        Task { await store.markRead(article, isRead: !article.isRead) }
                                    },
                                    onToggleSaved: {
                                        Task { await store.toggleSaved(article) }
                                    },
                                    onCopyLink: { copyLink(for: article) }
                                )
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func open(_ article: FeedArticleSummary) {
        selectedArticleID = article.articleID
        detail = nil
        Task {
            if store.marksReadOnOpen {
                await store.markRead(article, isRead: true)
            }
            isLoadingDetail = true
            detail = await store.detail(for: article)
            isLoadingDetail = false
        }
    }

    private func detailView(for article: FeedArticleSummary) -> some View {
        FeedArticleDetailView(
            article: article,
            detail: detail,
            favicon: store.faviconImages[article.feedURL],
            thumbnail: store.thumbnailImages[article.articleID],
            isLoading: isLoadingDetail,
            onOpenInCurrentTab: { openURL(for: article, newTab: false) },
            onOpenInNewTab: { openURL(for: article, newTab: true) },
            onClose: {
                selectedArticleID = nil
                detail = nil
            }
        )
        .task(id: article.articleID) {
            if store.thumbnailImages[article.articleID] == nil {
                _ = await store.thumbnail(for: article)
            }
            if store.faviconImages[article.feedURL] == nil,
                let subscription = store.subscriptions.first(where: { $0.feedURL == article.feedURL })
            {
                _ = await store.favicon(for: subscription)
            }
        }
    }

    private func openURL(for article: FeedArticleSummary, newTab: Bool) {
        guard let url = URL(string: article.url),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            NSSound.beep()
            return
        }
        coordinator.onOpenArticle?(url, newTab)
    }

    private func copyLink(for article: FeedArticleSummary) {
        guard !article.url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(article.url, forType: .string)
    }
}

/// Loads persisted card images without making the card itself stateful.
private struct FeedCardLoader<Content: View>: View {
    let article: FeedArticleSummary
    let content: (NSImage?, NSImage?) -> Content
    @ObservedObject private var coordinator = FeedReaderCoordinator.shared
    @State private var thumbnail: NSImage?
    @State private var favicon: NSImage?

    var body: some View {
        content(thumbnail, favicon)
            .task(id: article.articleID) {
                thumbnail = await coordinator.store.thumbnail(for: article)
                if let subscription = coordinator.store.subscriptions.first(where: { $0.feedURL == article.feedURL }) {
                    favicon = await coordinator.store.favicon(for: subscription)
                }
            }
    }
}

private extension FeedSubscription {
    var displayName: String {
        if !feedTitle.isEmpty { return feedTitle }
        if !siteName.isEmpty { return siteName }
        return feedURL
    }
}
