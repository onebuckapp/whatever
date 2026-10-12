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

import SwiftUI

/// The dedicated settings pane for feed discovery, fetching, parsing,
/// retention, subscriptions, and cleanup.
///
/// Behavior controls live in `AppSettings.FeedSettings` and persist through
/// `SettingsStore`. Subscriptions and cached articles live in the separate
/// feeds store and are managed here through the shared reader store, so this
/// pane never invents a second copy of subscription state.
struct RSSFeedsSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var reader = FeedReaderCoordinator.shared.store
    // Observed for `revision`: count labels re-resolve below without
    // reopening Settings.
    @ObservedObject private var localization = Localization.shared
    @State private var isConfirmingRemoveAll = false
    /// Finished count labels, resolved core-side in one batch call:
    /// status line, cached-content subtitle, and one "N unread" per source.
    @State private var statusText = ""
    @State private var cachedText = ""
    @State private var unreadLabels: [String: String] = [:]

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: tr("Reading", ctx: "Settings.Feeds"),
                footnote: tr("Discovery only advertises feeds. Nothing is downloaded or saved until a feed is subscribed or refreshed.", ctx: "Settings.Feeds")
            ) {
                SettingsToggleRow(
                    title: tr("Enable RSS feeds", ctx: "Settings.Feeds"),
                    subtitle: tr("Show the toolbar control on pages that advertise a feed and allow new subscriptions.", ctx: "Settings.Feeds"),
                    isOn: settings.binding(\.feeds.isEnabled)
                )
                SettingsToggleRow(
                    title: tr("Mark articles read on open", ctx: "Settings.Feeds"),
                    subtitle: tr("Opening an article clears its unread dot.", ctx: "Settings.Feeds"),
                    isOn: settings.binding(\.feeds.markArticlesReadOnOpen)
                )
            }

            SettingsGroup(
                title: tr("Fetching", ctx: "Settings.Feeds"),
                footnote: tr("Refreshes use conditional requests when the publisher supports them. Private tabs never subscribe, refresh, or download.", ctx: "Settings.Feeds"),
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                SettingsToggleRow(
                    title: tr("Refresh automatically", ctx: "Settings.Feeds"),
                    subtitle: tr("Refresh stale subscriptions when the reader loads them.", ctx: "Settings.Feeds"),
                    isOn: settings.binding(\.feeds.autoRefreshEnabled)
                )
                SettingsSliderRow(
                    title: tr("Refresh interval", ctx: "Settings.Feeds"),
                    value: settings.binding(\.feeds.refreshIntervalMinutes),
                    range: 5...180,
                    step: 5,
                    format: { String(format: "%.0f min", $0) }
                )
                SettingsButtonRow(
                    title: tr("Refresh all", ctx: "Settings.Feeds"),
                    subtitle: statusText
                ) {
                    Button(tr("Refresh", ctx: "Settings.Feeds")) {
                        Task { await reader.refreshAll() }
                    }
                    .controlSize(.small)
                    .disabled(reader.subscriptions.isEmpty || reader.isRefreshing)
                }
            }

            SettingsGroup(
                title: tr("Parsing", ctx: "Settings.Feeds"),
                footnote: tr("Strict parsing rejects malformed feeds and RDF/RSS 1.0. Lenient parsing recovers usable titles, links, dates, and summaries whenever they can still be identified.", ctx: "Settings.Feeds"),
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                SettingsToggleRow(
                    title: tr("Strict validation", ctx: "Settings.Feeds"),
                    subtitle: tr("Refuse feeds that fail RSS or Atom validation instead of recovering them.", ctx: "Settings.Feeds"),
                    isOn: settings.binding(\.feeds.strictParsing)
                )
                SettingsPickerRow(
                    title: tr("Thumbnails", ctx: "Settings.Feeds"),
                    options: AppSettings.FeedThumbnailPolicy.allCases,
                    selection: settings.binding(\.feeds.thumbnailPolicy),
                    label: { $0.title }
                )
                SettingsToggleRow(
                    title: tr("Download favicons", ctx: "Settings.Feeds"),
                    subtitle: tr("Persist one validated site icon per subscription.", ctx: "Settings.Feeds"),
                    isOn: settings.binding(\.feeds.downloadFavicons)
                )
            }

            SettingsGroup(
                title: tr("Headline crawl", ctx: "Settings.Feeds"),
                footnote: tr("The crawl hides itself when there is nothing to show. Text always uses the system label color, so it follows Light and Dark Mode.", ctx: "Settings.Feeds"),
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                SettingsToggleRow(
                    title: tr("Enable Crawl", ctx: "Settings.Feeds"),
                    subtitle: tr("Shows a scrolling bar that displays headlines at the bottom.", ctx: "Settings.Feeds"),
                    isOn: settings.binding(\.feeds.crawlEnabled)
                )
                SettingsSliderRow(
                    title: tr("Crawl speed", ctx: "Settings.Feeds"),
                    value: settings.binding(\.feeds.crawlSpeed),
                    range: 20...200,
                    step: 5,
                    format: { String(format: "%.0f pt/s", $0) }
                )
                SettingsPickerRow(
                    title: tr("Crawl direction", ctx: "Settings.Feeds"),
                    options: AppSettings.CrawlDirection.allCases,
                    selection: settings.binding(\.feeds.crawlDirection),
                    isSegmented: true,
                    label: { $0.title }
                )
                SettingsSliderRow(
                    title: tr("Font size", ctx: "Settings.Feeds"),
                    value: settings.binding(\.feeds.crawlFontSize),
                    range: 10...16,
                    step: 0.5,
                    format: { String(format: "%.1f pt", $0) }
                )
                SettingsSliderRow(
                    title: tr("Bar height", ctx: "Settings.Feeds"),
                    value: settings.binding(\.feeds.crawlBarHeight),
                    range: 22...40,
                    step: 1,
                    format: { String(format: "%.0f pt", $0) }
                )
                SettingsSliderRow(
                    title: tr("Background opacity", ctx: "Settings.Feeds"),
                    value: settings.binding(\.feeds.crawlBackgroundOpacity),
                    range: 0.3...1,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsSliderRow(
                    title: tr("Corner Radius", ctx: "Settings.Feeds"),
                    value: settings.binding(\.appearance.crawlCornerRadius),
                    range: AppSettings.AppearanceSettings.crawlCornerRadiusRange,
                    step: 0.5,
                    format: { String(format: "%.1f pt", $0) }
                )
                SettingsTextRow(
                    title: tr("Separator", ctx: "Settings.Feeds"),
                    subtitle: tr("1–2 characters shown between headlines.", ctx: "Settings.Feeds"),
                    text: settings.binding(\.feeds.crawlSeparator),
                    maxCharacters: CrawlContent.maxSeparatorLength
                )
            }

            SettingsGroup(
                title: tr("Retention", ctx: "Settings.Feeds"),                footnote: tr("Retention is applied after ingestion and whenever Apply is pressed. Read and saved marks never cause pruning on their own.", ctx: "Settings.Feeds"),
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                SettingsSliderRow(
                    title: tr("Articles per feed", ctx: "Settings.Feeds"),
                    value: retentionBinding,
                    range: 25...1_000,
                    step: 25,
                    format: { String(format: "%.0f", $0) }
                )
                SettingsButtonRow(
                    title: tr("Apply retention", ctx: "Settings.Feeds"),
                    subtitle: tr("Prune every subscription to the limit above.", ctx: "Settings.Feeds")
                ) {
                    Button(tr("Apply", ctx: "Settings.Feeds")) {
                        Task { await reader.applyRetention() }
                    }
                    .controlSize(.small)
                    .disabled(reader.subscriptions.isEmpty || reader.isRefreshing)
                }
            }

            SettingsGroup(
                title: tr("Subscribed sources", ctx: "Settings.Feeds"),
                footnote: settings.settings.feeds.isEnabled
                    ? tr("Unsubscribing removes the subscription, its cached articles, and its persisted images.", ctx: "Settings.Feeds")
                    : tr("Turn RSS feeds on to manage subscriptions.", ctx: "Settings.Feeds"),
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                if reader.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let failure = reader.failure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if reader.subscriptions.isEmpty {
                    Text(tr("No subscribed sources.", ctx: "Settings.Feeds"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                } else {
                    ForEach(reader.subscriptions) { subscription in
                        subscriptionRow(subscription)
                    }
                }
            }

            SettingsGroup(
                title: tr("Storage", ctx: "Settings.Feeds"),
                footnote: tr("Subscriptions, articles, favicons, and thumbnails live in the separate feeds database. Removing everything cannot be undone.", ctx: "Settings.Feeds"),
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                SettingsButtonRow(
                    title: tr("Cached content", ctx: "Settings.Feeds"),
                    subtitle: cachedText
                ) {
                    EmptyView()
                }
                if isConfirmingRemoveAll {
                    Text(tr("Remove every subscription and all cached articles and images?", ctx: "Settings.Feeds"))
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        Button(tr("Cancel", ctx: "Settings.Feeds")) {
                            isConfirmingRemoveAll = false
                        }
                        .controlSize(.small)
                        Button(tr("Remove everything", ctx: "Settings.Feeds"), role: .destructive) {
                            isConfirmingRemoveAll = false
                            Task { await reader.removeAllSubscriptions() }
                        }
                        .controlSize(.small)
                    }
                } else {
                    SettingsButtonRow(
                        title: tr("Remove everything", ctx: "Settings.Feeds"),
                        subtitle: tr("Delete all subscriptions and cached feeds.", ctx: "Settings.Feeds")
                    ) {
                        Button(tr("Remove", ctx: "Settings.Feeds")) {
                            isConfirmingRemoveAll = true
                        }
                        .controlSize(.small)
                        .disabled(reader.subscriptions.isEmpty || reader.isRefreshing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await reader.load()
        }
        .task(id: feedSignature) {
            await resolveCountLabels()
        }
    }

    /// Everything the count labels show, so one batch call refreshes them
    /// together whenever subscriptions or the language move.
    private var feedSignature: String {
        let rows = reader.subscriptions.map { "\($0.feedURL):\($0.unreadCount):\($0.articleCount)" }
        return (rows + ["\(localization.revision)"]).joined(separator: "|")
    }

    /// One batch call resolves the status line, the cached-content
    /// subtitle, and every row's "N unread" in the row's own words for
    /// every count. Static states keep their own sentences.
    private func resolveCountLabels() async {
        let subscriptions = reader.subscriptions
        if reader.isRefreshing {
            statusText = tr("Refreshing…", ctx: "Settings.Feeds")
        } else if subscriptions.isEmpty {
            statusText = tr("No subscriptions", ctx: "Settings.Feeds")
        } else {
            let texts = await Localization.batch([
                LocaleItem("one source", plural: "{n} sources", n: subscriptions.count),
            ])
            statusText = texts.first ?? "\(subscriptions.count) sources"
        }
        let articles = subscriptions.reduce(0) { $0 + $1.articleCount }
        let unread = subscriptions.reduce(0) { $0 + $1.unreadCount }
        var items = [
            LocaleItem("one article", plural: "{n} articles", n: articles),
            LocaleItem("one unread", plural: "{n} unread", n: unread),
            LocaleItem("one source", plural: "{n} sources", n: subscriptions.count),
        ]
        items += subscriptions.map { subscription in
            LocaleItem("one unread", plural: "{n} unread", n: subscription.unreadCount)
        }
        let texts = await Localization.batch(items)
        guard texts.count == items.count else { return }
        cachedText = "\(texts[0]) · \(texts[1]) across \(texts[2])"
        var labels: [String: String] = [:]
        for (offset, subscription) in subscriptions.enumerated() {
            labels[subscription.feedURL] = texts[3 + offset]
        }
        unreadLabels = labels
    }

    private var retentionBinding: Binding<Double> {
        Binding(
            get: { Double(settings.settings.feeds.maximumArticlesPerFeed) },
            set: { newValue in
                settings.update { document in
                    document.feeds.maximumArticlesPerFeed = Int(newValue.rounded())
                }
            }
        )
    }

    private func subscriptionRow(_ subscription: FeedSubscription) -> some View {
        HStack(spacing: 10) {
            if let favicon = reader.faviconImages[subscription.feedURL] {
                Image(nsImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(subscription.feedTitle.isEmpty ? subscription.siteName : subscription.feedTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(subscriptionStatus(subscription))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                Task { await reader.refresh(subscription, force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(tr("Refresh this source now", ctx: "Settings.Feeds"))
            .disabled(reader.isRefreshing)
            Button {
                Task { await reader.unsubscribe(subscription) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(tr("Unsubscribe from this source", ctx: "Settings.Feeds"))
            .disabled(reader.isRefreshing)
        }
        .padding(.vertical, 5)
        .task {
            if reader.faviconImages[subscription.feedURL] == nil {
                _ = await reader.favicon(for: subscription)
            }
        }
    }

    private func subscriptionStatus(_ subscription: FeedSubscription) -> String {
        var parts: [String] = []
        if !subscription.siteName.isEmpty {
            parts.append(subscription.siteName)
        }
        parts.append(unreadLabels[subscription.feedURL] ?? "\(subscription.unreadCount) unread")
        if !subscription.lastStatus.isEmpty {
            parts.append(subscription.lastStatus)
        }
        if !subscription.lastError.isEmpty {
            parts.append(subscription.lastError)
        }
        return parts.joined(separator: " · ")
    }
}
