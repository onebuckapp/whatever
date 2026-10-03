import AppKit
import SwiftUI

/// The detail pane for each settings section.
///
/// Split out from the modal chrome so the sidebar, the card, and the presenter
/// stay about layout and this file stays about the settings themselves.
enum SettingsDetailView {
    /// `AnyView` rather than `some View`: a switch over seven cases has seven
    /// unrelated concrete types, which `some View` cannot unify.
    static func view(for section: SettingsSection) -> AnyView {
        switch section {
        case .general: AnyView(GeneralSettingsView())
        case .appearance: AnyView(AppearanceSettingsView())
        case .web: AnyView(WebSettingsView())
        case .bookmarks: AnyView(BookmarksSettingsView())
        case .history: AnyView(HistorySettingsView())
        case .search: AnyView(SearchSettingsView())
        case .downloads: AnyView(DownloadsSettingsView())
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: "Session",
                footnote: "Restoring reopens the previous window's tabs."
            ) {
                SettingsToggleRow(
                    title: "Restore last session",
                    subtitle: "Reopen the previous window's tabs at launch.",
                    isOn: store.binding(\.general.restoreSession)
                )
            }

            SettingsGroup(
                title: "History",
                footnote: "Private tabs are never recorded, whatever this says."
            ) {
                SettingsToggleRow(
                    title: "Record visited pages",
                    subtitle: "Adds committed main-frame visits to history.",
                    isOn: store.binding(\.general.recordsHistory)
                )
                SettingsSliderRow(
                    title: "Collapse repeats within",
                    value: store.binding(\.general.historyCollapseWindow),
                    range: 0...120,
                    step: 1,
                    format: { String(format: "%.0f s", $0) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @ObservedObject private var grain = NoiseOverlaySettings.shared

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: "Grain",
                footnote: "A film-grain texture over the whole window. Every change applies as you make it."
            ) {
                SettingsToggleRow(
                    title: "Enabled",
                    subtitle: "Hides the texture without losing these settings.",
                    isOn: grain.enabledBinding
                )
                SettingsButtonRow(
                    title: "New pattern",
                    subtitle: "Same settings, different grain."
                ) {
                    Button {
                        grain.rerollSeed()
                    } label: {
                        Image(systemName: "dice")
                    }
                    .help("Generate a different grain")
                    .buttonStyle(.borderless)
                }
                SettingsButtonRow(
                    title: "Reset",
                    subtitle: "Back to the built-in grain."
                ) {
                    Button("Reset") {
                        grain.reset()
                    }
                    .controlSize(.small)
                }
            }

            SettingsGroup(
                title: "Look",
                isEnabled: grain.configuration.isEnabled
            ) {
                SettingsPickerRow(
                    title: "Color",
                    options: GrainColorMode.allCases,
                    selection: grain.colorModeBinding,
                    isSegmented: true,
                    label: { $0.title }
                )
                SettingsSliderRow(
                    title: "Opacity",
                    value: grain.opacityBinding,
                    range: 0...0.5,
                    step: 0.05,
                    format: { String(format: "%.2f", $0) }
                )
                SettingsSliderRow(
                    title: "Intensity",
                    value: grain.intensityBinding,
                    range: 0...1,
                    step: 0.05,
                    format: { String(format: "%.2f", $0) }
                )
                SettingsSliderRow(
                    title: "Contrast",
                    value: grain.contrastBinding,
                    range: 1...8,
                    step: 0.1,
                    format: { String(format: "%.1f", $0) }
                )
                SettingsSliderRow(
                    title: "Grain Size",
                    value: grain.grainScaleBinding,
                    range: 1...4,
                    step: 0.1,
                    format: { String(format: "%.1f", $0) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Web

struct WebSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: "Pages",
                footnote: "These are read when a page view is built. Changing one takes effect on the next page."
            ) {
                SettingsToggleRow(
                    title: "Allow JavaScript",
                    subtitle: "Off blocks scripts, which also stops most sites from working.",
                    isOn: store.binding(\.web.allowsJavaScript)
                )
                SettingsToggleRow(
                    title: "Upgrade known hosts to HTTPS",
                    isOn: store.binding(\.web.upgradeKnownHostsToHTTPS)
                )
            }

            SettingsGroup(
                title: "Privacy",
                footnote: "Applies to pages opened from now on."
            ) {
                SettingsToggleRow(
                    title: "Fraudulent website warnings",
                    isOn: store.binding(\.web.fraudulentWebsiteWarningEnabled)
                )
                SettingsToggleRow(
                    title: "Site-specific quirks mode",
                    isOn: store.binding(\.web.siteSpecificQuirksModeEnabled)
                )
                SettingsToggleRow(
                    title: "JavaScript may open windows",
                    isOn: store.binding(\.web.javaScriptCanOpenWindowsAutomatically)
                )
            }

            SettingsGroup(title: "Display", footnote: "Applies to open pages immediately.") {
                SettingsSliderRow(
                    title: "Page zoom",
                    value: store.binding(\.web.pageZoom),
                    range: 0.5...3,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsSliderRow(
                    title: "Minimum font size",
                    value: store.binding(\.web.minimumFontSize),
                    range: 0...24,
                    step: 1,
                    format: { $0 == 0 ? "off" : String(format: "%.0f pt", $0) }
                )
            }

            SettingsGroup(title: "Interaction") {
                SettingsToggleRow(
                    title: "Back/forward gestures",
                    isOn: store.binding(\.web.allowsBackForwardNavigationGestures)
                )
                SettingsToggleRow(
                    title: "Magnification",
                    isOn: store.binding(\.web.allowsMagnification)
                )
                SettingsToggleRow(
                    title: "Link previews",
                    isOn: store.binding(\.web.allowsLinkPreview)
                )
                SettingsToggleRow(
                    title: "Tab focuses links",
                    isOn: store.binding(\.web.tabFocusesLinks)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Bookmarks

struct BookmarksSettingsView: View {
    @State private var entries: [BookmarkSummary] = []
    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Text("Bookmarks")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Remove All") {
                Task { await clearAll() }
            }
            .controlSize(.small)
            .disabled(entries.isEmpty || isLoading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure {
            SettingsPlaceholder(
                symbol: "exclamationmark.triangle",
                title: "Bookmarks unavailable",
                message: failure
            )
        } else if entries.isEmpty {
            SettingsPlaceholder(
                symbol: "bookmark",
                title: "No bookmarks yet",
                message: "Bookmarks you add will be listed here."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func row(_ entry: BookmarkSummary) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? entry.url : entry.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(entry.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                Task { await remove(entry) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Remove this bookmark")
        }
        .padding(.vertical, 6)
    }

    private func load() async {
        do {
            let data = try await StoreClient.shared.bookmarks()
            entries = BookmarkSummary.decodeList(data)
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }

    private func remove(_ entry: BookmarkSummary) async {
        do {
            try await StoreClient.shared.deleteBookmark(id: entry.id)
            entries.removeAll { $0.id == entry.id }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func clearAll() async {
        do {
            try await StoreClient.shared.clearBookmarks()
            entries = []
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// One bookmark as the settings list needs it.
///
/// The store holds whatever JSON the app gave it, so the list reads the two
/// fields it shows and tolerates their absence rather than failing the decode.
struct BookmarkSummary: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let url: String

    private enum CodingKeys: String, CodingKey {
        case id, title, url
    }

    init(id: String, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
    }

    /// Decodes a stored array, skipping rows that are not objects.
    ///
    /// A single malformed bookmark should cost that bookmark, not the list.
    static func decodeList(_ data: Data) -> [BookmarkSummary] {
        guard let root = try? JSONDecoder().decode([FailableBookmark].self, from: data) else {
            return []
        }
        return root.compactMap(\.value)
    }

    private struct FailableBookmark: Decodable {
        let value: BookmarkSummary?

        init(from decoder: Decoder) throws {
            value = try? BookmarkSummary(from: decoder)
        }
    }
}

// MARK: - History

struct HistorySettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var entries: [HistoryEntry] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            recordingControls
            Divider()
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
        .onChange(of: store.settings.general.recordsHistory) {
            Task { await load() }
        }
    }

    private var header: some View {
        HStack {
            Text("History")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Delete Older Than 30 Days") {
                Task { await deleteOlderThan() }
            }
            .controlSize(.small)
            .disabled(isLoading)
            Button("Clear All") {
                Task { await clearAll() }
            }
            .controlSize(.small)
            .disabled(isLoading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsToggleRow(
                title: "Record visited pages",
                subtitle: "Private tabs are never recorded, whatever this says.",
                isOn: store.binding(\.general.recordsHistory)
            )
            SettingsSliderRow(
                title: "Collapse repeats within",
                value: store.binding(\.general.historyCollapseWindow),
                range: 0...120,
                step: 1,
                format: { String(format: "%.0f s", $0) }
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        if isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            SettingsPlaceholder(
                symbol: "clock",
                title: "No history yet",
                message: "Pages you visit show up here."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? entry.url : entry.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(entry.host.isEmpty ? entry.url : entry.host)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(entry.visitCount > 1 ? "\(entry.visitCount) visits" : "")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Button {
                Task { await remove(entry) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Remove this entry")
        }
        .padding(.vertical, 6)
    }

    private func load() async {
        do {
            entries = HistoryEntry.decodeList(try await StoreClient.shared.recentHistory(limit: 200))
        } catch {
            entries = []
        }
        isLoading = false
    }

    private func remove(_ entry: HistoryEntry) async {
        do {
            try await StoreClient.shared.deleteHistoryEntry(id: entry.id)
            entries.removeAll { $0.id == entry.id }
        } catch {
            // Leave the row in place: a failed delete that looks like a
            // successful one is worse than one that visibly did nothing.
        }
    }

    private func deleteOlderThan() async {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        guard (try? await StoreClient.shared.deleteHistory(olderThan: cutoff)) != nil else { return }
        await load()
    }

    private func clearAll() async {
        guard (try? await StoreClient.shared.clearHistory()) != nil else { return }
        entries = []
    }
}

// MARK: - Search

struct SearchSettingsView: View {
    var body: some View {
        SettingsPlaceholder(
            symbol: "magnifyingglass",
            title: "Search is DuckDuckGo",
            message: "The address bar sends searches to DuckDuckGo. A choice of engine is coming."
        )
    }
}

// MARK: - Downloads

struct DownloadsSettingsView: View {
    var body: some View {
        SettingsPlaceholder(
            symbol: "arrow.down.circle",
            title: "No download history yet",
            message: "Downloads appear here once Whatever tracks them."
        )
    }
}