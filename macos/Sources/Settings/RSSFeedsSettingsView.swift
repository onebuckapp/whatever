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
    @State private var isConfirmingRemoveAll = false

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: "Reading",
                footnote: "Discovery only advertises feeds. Nothing is downloaded or saved until a feed is subscribed or refreshed."
            ) {
                SettingsToggleRow(
                    title: "Enable RSS feeds",
                    subtitle: "Show the toolbar control on pages that advertise a feed and allow new subscriptions.",
                    isOn: settings.binding(\.feeds.isEnabled)
                )
                SettingsToggleRow(
                    title: "Mark articles read on open",
                    subtitle: "Opening an article clears its unread dot.",
                    isOn: settings.binding(\.feeds.markArticlesReadOnOpen)
                )
            }

            SettingsGroup(
                title: "Fetching",
                footnote: "Refreshes use conditional requests when the publisher supports them. Private tabs never subscribe, refresh, or download.",
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                SettingsToggleRow(
                    title: "Refresh automatically",
                    subtitle: "Refresh stale subscriptions when the reader loads them.",
                    isOn: settings.binding(\.feeds.autoRefreshEnabled)
                )
                SettingsSliderRow(
                    title: "Refresh interval",
                    value: settings.binding(\.feeds.refreshIntervalMinutes),
                    range: 5...180,
                    step: 5,
                    format: { String(format: "%.0f min", $0) }
                )
                SettingsButtonRow(
                    title: "Refresh all",
                    subtitle: statusSummary
                ) {
                    Button("Refresh") {
                        Task { await reader.refreshAll() }
                    }
                    .controlSize(.small)
                    .disabled(reader.subscriptions.isEmpty || reader.isRefreshing)
                }
            }

            SettingsGroup(
                title: "Parsing",
                footnote: "Strict parsing rejects malformed feeds and RDF/RSS 1.0. Lenient parsing recovers usable titles, links, dates, and summaries whenever they can still be identified.",
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                SettingsToggleRow(
                    title: "Strict validation",
                    subtitle: "Refuse feeds that fail RSS or Atom validation instead of recovering them.",
                    isOn: settings.binding(\.feeds.strictParsing)
                )
                SettingsPickerRow(
                    title: "Thumbnails",
                    options: AppSettings.FeedThumbnailPolicy.allCases,
                    selection: settings.binding(\.feeds.thumbnailPolicy),
                    label: { $0.title }
                )
                SettingsToggleRow(
                    title: "Download favicons",
                    subtitle: "Persist one validated site icon per subscription.",
                    isOn: settings.binding(\.feeds.downloadFavicons)
                )
            }

            SettingsGroup(
                title: "Retention",
                footnote: "Retention is applied after ingestion and whenever Apply is pressed. Read and saved marks never cause pruning on their own.",
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                SettingsSliderRow(
                    title: "Articles per feed",
                    value: retentionBinding,
                    range: 25...1_000,
                    step: 25,
                    format: { String(format: "%.0f", $0) }
                )
                SettingsButtonRow(
                    title: "Apply retention",
                    subtitle: "Prune every subscription to the limit above."
                ) {
                    Button("Apply") {
                        Task { await reader.applyRetention() }
                    }
                    .controlSize(.small)
                    .disabled(reader.subscriptions.isEmpty || reader.isRefreshing)
                }
            }

            SettingsGroup(
                title: "Subscribed sources",
                footnote: settings.settings.feeds.isEnabled
                    ? "Unsubscribing removes the subscription, its cached articles, and its persisted images."
                    : "Turn RSS feeds on to manage subscriptions.",
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
                    Text("No subscribed sources.")
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
                title: "Storage",
                footnote: "Subscriptions, articles, favicons, and thumbnails live in the separate feeds database. Removing everything cannot be undone.",
                isEnabled: settings.settings.feeds.isEnabled
            ) {
                SettingsButtonRow(
                    title: "Cached content",
                    subtitle: "\(totalArticles) articles · \(totalUnread) unread across \(reader.subscriptions.count) sources"
                ) {
                    EmptyView()
                }
                if isConfirmingRemoveAll {
                    Text("Remove every subscription and all cached articles and images?")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        Button("Cancel") {
                            isConfirmingRemoveAll = false
                        }
                        .controlSize(.small)
                        Button("Remove everything", role: .destructive) {
                            isConfirmingRemoveAll = false
                            Task { await reader.removeAllSubscriptions() }
                        }
                        .controlSize(.small)
                    }
                } else {
                    SettingsButtonRow(
                        title: "Remove everything",
                        subtitle: "Delete all subscriptions and cached feeds."
                    ) {
                        Button("Remove", role: .destructive) {
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

    private var statusSummary: String {
        if reader.isRefreshing {
            return "Refreshing…"
        }
        if reader.subscriptions.isEmpty {
            return "No subscriptions"
        }
        return "\(reader.subscriptions.count) sources"
    }

    private var totalArticles: Int {
        reader.subscriptions.reduce(0) { $0 + $1.articleCount }
    }

    private var totalUnread: Int {
        reader.subscriptions.reduce(0) { $0 + $1.unreadCount }
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
            .help("Refresh this source now")
            .disabled(reader.isRefreshing)
            Button {
                Task { await reader.unsubscribe(subscription) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Unsubscribe from this source")
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
        parts.append("\(subscription.unreadCount) unread")
        if !subscription.lastStatus.isEmpty {
            parts.append(subscription.lastStatus)
        }
        if !subscription.lastError.isEmpty {
            parts.append(subscription.lastError)
        }
        return parts.joined(separator: " · ")
    }
}
