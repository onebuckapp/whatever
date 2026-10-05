import AppKit
import SwiftUI

/// The detail pane for each settings section.
///
/// Split out from the modal chrome so the sidebar, the card, and the presenter
/// stay about layout and this file stays about the settings themselves.
enum SettingsDetailView {
    /// `AnyView` rather than `some View`: a switch over eight cases has eight
    /// unrelated concrete types, which `some View` cannot unify.
    static func view(for section: SettingsSection) -> AnyView {
        switch section {
        case .general: AnyView(GeneralSettingsView())
        case .appearance: AnyView(AppearanceSettingsView())
        case .web: AnyView(WebSettingsView())
        case .contentBlocker: AnyView(ContentBlockerSettingsView())
        case .bookmarks: AnyView(BookmarksSettingsView())
        case .rssFeeds: AnyView(RSSFeedsSettingsView())
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
                    Button("Generate") {
                        grain.rerollSeed()
                    }
                    .controlSize(.small)
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
                    format: { String(format: "%.1f×", $0) }
                )
            }

            BackgroundSettingsGroups()
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
        content
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

    /// The pane body, which is either a placeholder centered on its own or a
    /// list under the header.
    ///
    /// The placeholder is deliberately the whole body rather than the leftover
    /// space under the header. A placeholder centers itself in the space it is
    /// given, so nesting it below the header put its center lower than the same
    /// placeholder in a pane with no header, and History lower still because it
    /// has more chrome above it. Hiding the header when there is nothing to list
    /// is also the honest version: the header's only controls are disabled here.
    @ViewBuilder
    private var content: some View {
        if isLoading {
            listed {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
            listed {
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
    }

    /// Header and divider above a body that has rows under them.
    private func listed<Content: View>(_ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body()
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
        list
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

    /// The pane body. See `BookmarksSettingsView.content` for why the empty
    /// states drop the header rather than sitting under it.
    @ViewBuilder
    private var list: some View {
        if isLoading {
            listed {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if entries.isEmpty {
            SettingsPlaceholder(
                symbol: "clock",
                title: "No history yet",
                message: "Pages you visit show up here."
            )
        } else {
            listed {
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
    }

    /// Header, divider and the recording controls above a body that has rows
    /// under them.
    private func listed<Content: View>(_ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            recordingControls
            Divider()
            body()
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
    @ObservedObject private var store = SettingsStore.shared
    @State private var isAdding = false
    @State private var draft = CustomSearchEngine()

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: "Default Engine",
                footnote: "What the address field sends a search to. Anything that looks like a web address still loads directly."
            ) {
                ForEach(PredefinedSearchEngine.allCases) { engine in
                    SettingsRadioRow(
                        title: engine.title,
                        subtitle: engine.isPrivate ? nil : "Records what you search for",
                        isSelected: store.settings.search.isSelected(engine.rawValue)
                    ) {
                        select(engine.rawValue)
                    }
                }
            }

            customGroup

            if isAdding {
                addForm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The added engines, and the way into the form.
    ///
    /// Its own group rather than a section of the list above, so it is obvious
    /// which engines ship with the app and which the user added.
    @ViewBuilder
    private var customGroup: some View {
        SettingsGroup(
            title: "Your Engines",
            footnote: store.settings.search.customEngines.isEmpty
                ? "Add an engine to search somewhere these do not go."
                : nil
        ) {
            ForEach(store.settings.search.customEngines) { engine in
                SettingsRadioRow(
                    title: engine.name,
                    subtitle: engine.address,
                    isSelected: store.settings.search.isSelected(engine.id.uuidString)
                ) {
                    select(engine.id.uuidString)
                } accessory: {
                    Button {
                        remove(engine)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Remove this engine")
                }
            }

            SettingsButtonRow(
                title: isAdding ? "Cancel" : "Add Engine",
                subtitle: "An address, and the query parameter it takes."
            ) {
                Button(isAdding ? "Cancel" : "Add") {
                    if isAdding {
                        isAdding = false
                    } else {
                        draft = CustomSearchEngine()
                        isAdding = true
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// The add form, shown in place rather than as a dialog.
    ///
    /// In place keeps the validation message next to the field it is about, which
    /// is the whole reason to show it at all.
    private var addForm: some View {
        SettingsGroup(title: "New Engine") {
            labelledField("Name", text: $draft.name, placeholder: "My search")
            labelledField("Address", text: $draft.address, placeholder: "https://example.com/search")
            labelledField("Query parameter", text: $draft.queryItem, placeholder: "q")

            if let problem {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isAdding = false
                }
                .controlSize(.small)
                Button("Save") {
                    add()
                }
                .controlSize(.small)
                .disabled(problem != nil)
            }
        }
    }

    private func labelledField(
        _ title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11))
        }
        .padding(.vertical, 2)
    }

    /// Why the draft cannot be saved, or nil when it can.
    ///
    /// Reached through the trimmed values so a field of only spaces is rejected
    /// the same way an empty one is.
    private var problem: String? {
        CustomEngineValidator.problem(
            name: draft.name,
            address: draft.address,
            queryItem: draft.queryItem
        )
    }

    private func select(_ id: String) {
        store.update { document in
            document.search.defaultEngine = id
        }
    }

    private func add() {
        guard problem == nil else { return }
        var engine = draft
        // Trimmed on the way in, so the saved engine has no stray whitespace to
        // break its address or its name in the list.
        engine.name = engine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.address = engine.address.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.queryItem = engine.queryItem.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update { document in
            document.search.customEngines.append(engine)
            document.search.defaultEngine = engine.id.uuidString
        }
        isAdding = false
    }

    /// Removes an engine, and moves the default off it if it was selected.
    ///
    /// Leaving `defaultEngine` pointing at a deleted engine would work, because
    /// `engine()` falls back, but the list would then show nothing selected. Moving
    /// the default keeps the two consistent.
    private func remove(_ engine: CustomSearchEngine) {
        store.update { document in
            document.search.customEngines.removeAll { $0.id == engine.id }
            if document.search.defaultEngine == engine.id.uuidString {
                document.search.defaultEngine = PredefinedSearchEngine.duckDuckGo.rawValue
            }
        }
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

// MARK: - Content Blocker

struct ContentBlockerSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var blocker = ContentBlockerStore.shared
    @State private var rulesDraft = ""
    @State private var rulesSeeded = false
    @State private var hostDraft = ""

    private var exceptions: [String] {
        store.settings.adblock.exceptions.sorted()
    }

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: "Blocking",
                footnote: "Pages reload to pick up a change."
            ) {
                SettingsToggleRow(
                    title: "Block ads and trackers",
                    subtitle: "Third-party requests to listed hosts never leave the page.",
                    isOn: store.binding(\.adblock.enabled)
                )
            }

            SettingsGroup(
                title: "Filter lists",
                footnote: "Ships with the app. Nothing is downloaded and no browsing data leaves the machine: lists compile on device."
            ) {
                SettingsButtonRow(
                    title: "Bundled snapshot",
                    subtitle: "\(store.settings.adblock.snapshotVersion ?? "—") · \(blocker.lastMeta?.ruleCount ?? 0) rules"
                ) {
                    EmptyView()
                }
                SettingsButtonRow(
                    title: "Source",
                    subtitle: "AdAway default blocklist · CC BY 3.0 · plus our own extras"
                ) {
                    EmptyView()
                }
                if let meta = blocker.lastMeta {
                    SettingsButtonRow(
                        title: "Rules",
                        subtitle: "\(meta.blockCount) hosts · \(meta.cosmeticCount) hiding · \(meta.exceptionCount) exceptions"
                    ) {
                        EmptyView()
                    }
                    SettingsButtonRow(
                        title: "Skipped lines",
                        subtitle: "\(meta.skippedLines) lines the compiler ignored"
                    ) {
                        EmptyView()
                    }
                }
                if let error = blocker.lastError {
                    SettingsButtonRow(
                        title: "Last error",
                        subtitle: error
                    ) {
                        EmptyView()
                    }
                }
            }

            SettingsGroup(
                title: "Custom rules",
                footnote: "Hosts lines plus ||, @@ and ## rules, one per line. Applied together with the snapshot."
            ) {
                TextEditor(text: $rulesDraft)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 120)
                HStack {
                    Spacer(minLength: 0)
                    Button("Apply rules") { applyRules() }
                        .controlSize(.small)
                }
            }

            SettingsGroup(
                title: "Exceptions",
                footnote: "Sites the blocker leaves alone, subdomains included."
            ) {
                if exceptions.isEmpty {
                    Text("No exceptions.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                } else {
                    ForEach(exceptions, id: \.self) { host in
                        HStack {
                            Text(host)
                                .font(.system(size: 12))
                            Spacer(minLength: 12)
                            Button {
                                remove(host)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(host)")
                        }
                        .padding(.vertical, 3)
                    }
                }
                HStack {
                    TextField("example.com", text: $hostDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { add() }
                    Button("Add", action: add)
                        .controlSize(.small)
                        .disabled(normalizedHost(hostDraft) == nil)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Seed once per mount: the card keeps panes mounted while it is
            // open, so seeding on every appear would clobber an in-progress
            // edit whenever the pane is revisited.
            if !rulesSeeded {
                rulesDraft = store.settings.adblock.userRules
                rulesSeeded = true
            }
        }
    }

    private func applyRules() {
        let text = rulesDraft
        store.update { document in
            document.adblock.userRules = text
        }
        // The settings write above fans out through onChange, but the lists
        // themselves are stale until recompiled; compiling records the new
        // fingerprint, whose write fans out a second time with fresh lists.
        Task { @MainActor in
            await blocker.refreshIfNeeded()
        }
    }

    private func add() {
        guard let host = normalizedHost(hostDraft) else { return }
        store.update { document in
            document.adblock.exceptions.insert(host)
        }
        hostDraft = ""
    }

    private func remove(_ host: String) {
        store.update { document in
            document.adblock.exceptions.remove(host)
        }
    }

    /// Lowercased, trimmed and dot-trimmed, or nil when there is nothing to
    /// save. Matching is suffix-based, so the entry needs no further form.
    private func normalizedHost(_ raw: String) -> String? {
        let host = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty ? nil : host
    }
}