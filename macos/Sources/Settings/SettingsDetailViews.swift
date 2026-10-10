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
    @StateObject private var defaultBrowser = DefaultBrowserSettings()
    @StateObject private var updater = AppUpdateSettings()

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: "Software Update",
                footnote: "Whatever never updates itself. Checking asks GitHub for the latest release; downloading fetches its disk image for this Mac, and updating from it stays in your hands."
            ) {
                HStack(spacing: 12) {
                    // The app's own icon, fixed at 32pt: it names what the
                    // row updates without spending any words on it. An
                    // NSImageView rather than `Image(nsImage:)`, because
                    // SwiftUI rasterizes the NSImage at point size and
                    // upscales it — visibly soft on retina — while AppKit
                    // picks the 64px representation for a 32pt frame.
                    AppIconView()
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    SettingsButtonRow(
                        title: updater.title,
                        subtitle: updater.subtitle
                    ) {
                        updateAccessory
                    }
                }
            }

            SettingsGroup(
                title: "Default Browser",
                footnote: "Links clicked in other apps open here."
            ) {
                SettingsButtonRow(
                    title: defaultBrowser.isDefault
                        ? "Whatever is your default browser"
                        : "Whatever is not your default browser",
                    subtitle: defaultBrowser.isDefault
                        ? "This Mac already opens web links in Whatever."
                        : "Claim http and https links from your current browser."
                ) {
                    if !defaultBrowser.isDefault {
                        Button("Set Whatever as Default Browser") {
                            Task { await defaultBrowser.makeDefault() }
                        }
                        .controlSize(.small)
                    }
                }
            }

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
        .onAppear { defaultBrowser.refresh() }
    }

    /// The update row's trailing control under `updater.status`: a check
    /// button at rest, a spinner while busy, the download button when an
    /// update is ready, and a Finder reveal once it has landed.
    @ViewBuilder
    private var updateAccessory: some View {
        switch updater.status {
        case .idle, .upToDate, .failed, .noCompatibleDownload:
            Button("Check for Updates") {
                Task { await updater.checkForUpdates() }
            }
            .controlSize(.small)
        case .checking, .downloading:
            ProgressView()
                .controlSize(.small)
        case .available:
            Button("Download Update") {
                Task { await updater.downloadUpdate() }
            }
            .controlSize(.small)
        case .downloaded:
            Button("Show in Finder") {
                updater.revealDownload()
            }
            .controlSize(.small)
        }
    }
}

/// The app icon for SwiftUI, retina-sharp at a 32pt frame.
///
/// Two traps, both taken: `Image(nsImage:)` on the raw app icon snapshots
/// at point resolution (soft on retina), and adding `.resizable()` keeps it
/// soft — the image is rasterized once at 1x and upscaled, ignoring any
/// extra representations. So the icon is rasterized up front with explicit
/// 1x/2x/3x bitmaps at a 32pt size and drawn without `.resizable()`, which
/// is what lets the renderer pick the 64px bitmap on a retina screen.
/// (An `NSImageView` representable was tried between the two and cropped:
/// the 512pt intrinsic size won over the frame.)
struct AppIconView: View {
    var body: some View {
        Image(nsImage: Self.iconImage)
            .frame(width: 32, height: 32)
    }

    /// Cached: three tiny bitmaps, rendered once rather than per body
    /// evaluation. First touched from a body, so always on the main thread.
    static var iconImage: NSImage { rasterized }

    private static let rasterized: NSImage = {
        let points: CGFloat = 32
        let image = NSImage(size: NSSize(width: points, height: points))
        // Nil in principle (no icon set); then this stays a blank 32pt
        // image rather than crashing the settings pane.
        guard let source = NSApplication.shared.applicationIconImage else {
            return image
        }
        for scale in [1, 2, 3] {
            let pixels = Int(points) * scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                continue
            }
            rep.size = NSSize(width: points, height: points)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(
                in: NSRect(x: 0, y: 0, width: points, height: points),
                from: NSRect.zero,
                operation: .copy,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }()
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @ObservedObject private var grain = NoiseOverlaySettings.shared
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterField
            SettingsDetailStack {
                if matches("Grain", "grain texture film noise pattern") {
                    grainGroup
                }
                if matches("Look", "look color colour opacity intensity contrast size") {
                    lookGroup
                }
                if matches(
                    "Window Background",
                    "background wallpaper backdrop image video fill page corners rounded"
                ) {
                    BackgroundSettingsGroups()
                }
                if matches(
                    "Inactive Tabs Current Tab",
                    "tab tabs theme inactive current foreground text color colour corner corners rounded"
                ) {
                    TabThemeSettingsGroups()
                }
                if matches(
                    "Address Bar",
                    "address bar field width pill corner corners height rounded"
                ) {
                    AddressBarSettingsGroups()
                }
                if !filter.isEmpty, !hasAnyMatch {
                    Text("No settings match “\(filter.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Pinned above the scrolling groups: typing narrows the pane to the
    /// matching sections, clearing restores everything.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Filter settings", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        // Aligned with the group content below (which pads 20 horizontally),
        // daylight above it, and nothing below: the stack spacing owns that
        // gap, so padding here too would double it.
        .padding([.leading, .trailing], 20)
        .padding(.top, 18)
    }

    /// Every query word must appear in the title or keywords. Empty filter
    /// matches everything, so the pane opens unfiltered.
    private func matches(_ title: String, _ keywords: String) -> Bool {
        SettingsFilter.matches(query: filter, haystack: "\(title) \(keywords)")
    }

    private var hasAnyMatch: Bool {
        matches("Grain", "grain texture film noise pattern")
            || matches("Look", "look color colour opacity intensity contrast size")
            || matches("Window Background", "background wallpaper backdrop image video fill")
            || matches("Inactive Tabs Current Tab", "tab tabs theme inactive current foreground text color colour")
            || matches("Address Bar", "address bar field width pill corner corners height rounded")
    }

    private var grainGroup: some View {
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
    }

    private var lookGroup: some View {
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
    }
}

    // MARK: - Web

struct WebSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: "Pages",
                footnote: Self.effect(of: [\AppSettings.WebSettings.allowsJavaScript])
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
                SettingsToggleRow(
                    title: "JavaScript may open windows",
                    subtitle: "Lets a page open a tab without a click. Popups land in this window.",
                    isOn: store.binding(\.web.javaScriptCanOpenWindowsAutomatically)
                )
            }

            SettingsGroup(
                title: "Media",
                footnote: Self.effect(of: [\AppSettings.WebSettings.mediaAutoplay])
            ) {
                SettingsPickerRow(
                    title: "Play without a click",
                    options: AppSettings.MediaAutoplayPolicy.allCases,
                    selection: store.binding(\.web.mediaAutoplay),
                    label: Self.autoplayLabel
                )
            }

            SettingsGroup(
                title: "Privacy",
                footnote: Self.effect(of: [
                    \AppSettings.WebSettings.fraudulentWebsiteWarningEnabled,
                    \AppSettings.WebSettings.siteSpecificQuirksModeEnabled,
                ])
            ) {
                SettingsToggleRow(
                    title: "Fraudulent website warnings",
                    isOn: store.binding(\.web.fraudulentWebsiteWarningEnabled)
                )
                SettingsToggleRow(
                    title: "Site-specific quirks mode",
                    isOn: store.binding(\.web.siteSpecificQuirksModeEnabled)
                )
            }

            SettingsGroup(
                title: "Display",
                footnote: Self.effect(of: [
                    \AppSettings.WebSettings.pageZoom,
                    \AppSettings.WebSettings.minimumFontSize,
                ])
            ) {
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

            SettingsGroup(
                title: "Sleeping tabs",
                // Hand-written rather than the derived engine footnote: this
                // is app behaviour, not a WebKit property, and neither
                // "applies immediately" nor "needs a new page" describes a
                // minute-cadence reaper.
                footnote: "Hidden tabs past this idle time lose their page and free its memory. Showing one reloads its address; displayed, pinned, sounding, and loading tabs never sleep."
            ) {
                SettingsPickerRow(
                    title: "Sleep unused tabs",
                    options: AppSettings.InactiveTabSleep.allCases,
                    selection: store.binding(\.web.sleepInactiveTabs),
                    label: { $0.label }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// What the group needs to say about when a change lands.
    ///
    /// Answers from the key paths rather than being written by hand, because the
    /// hand-written version drifted: the Display group promised "applies to open
    /// pages immediately" directly above a minimum font size that WebKit only
    /// reads while building a view. Derived from the same
    /// `configTimeWebKeys` the application path uses, so the two cannot disagree.
    ///
    /// A group holding both kinds says so, which is the honest answer and is why
    /// `Upgrade known hosts to HTTPS` and `JavaScript may open windows` moved up
    /// into Pages: they are config-time, and the Pages group was already saying
    /// so.
    private static func effect<Value>(of keyPaths: [KeyPath<AppSettings.WebSettings, Value>]) -> String {
        let needsNewPage = keyPaths.filter { AppSettings.needsNewPage($0) }.count
        if needsNewPage == 0 {
            return "Applies to open pages immediately."
        }
        if needsNewPage == keyPaths.count {
            return "Read when a page is opened. Changes take effect on the next page."
        }
        return "Some of these take effect on the next page."
    }

    private static func autoplayLabel(_ policy: AppSettings.MediaAutoplayPolicy) -> String {
        switch policy {
        case .never: "Nothing"
        case .video: "Video"
        case .audio: "Audio"
        case .all: "Everything"
        }
    }
}

// MARK: - Bookmarks

/// The bookmarks pane: the bar toggle, then the saved tree.
///
/// Renders the same `BookmarkStore` the bar and the star use, so a save
/// from any surface appears here without a reload, and folders nest the way
/// they do on the bar.
struct BookmarksSettingsView: View {
    @ObservedObject private var store = BookmarkStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            visibility
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if !store.isLoaded {
                await store.load()
            }
        }
    }

    /// The bar's visibility toggle, above the list and always visible: with
    /// no bookmarks yet the bar is still the way to create the first one,
    /// so the control cannot live inside the list's header.
    private var visibility: some View {
        HStack {
            Toggle(
                "Show bookmarks bar",
                isOn: SettingsStore.shared.binding(\.bookmarks.showBar)
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack {
            Text("Bookmarks")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Remove All") {
                store.removeAll()
            }
            .controlSize(.small)
            .disabled(store.nodes.isEmpty || !store.isLoaded)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// The pane body, which is either a placeholder centered on its own or a
    /// list under the header.
    ///
    /// The placeholder is deliberately the whole body rather than the
    /// leftover space under the header: the header's only controls are
    /// disabled when there is nothing to list, so hiding it is the honest
    /// version, same as the other panes.
    @ViewBuilder
    private var content: some View {
        if !store.isLoaded {
            listed {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let failure = store.lastError, store.nodes.isEmpty {
            SettingsPlaceholder(
                symbol: "exclamationmark.triangle",
                title: "Bookmarks unavailable",
                message: failure
            )
        } else if store.nodes.isEmpty {
            SettingsPlaceholder(
                symbol: "bookmark",
                title: "No bookmarks yet",
                message: "Bookmarks you add will be listed here."
            )
        } else {
            listed {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.roots) { node in
                            BookmarkSettingsRow(node: node, store: store)
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
}

/// One row of the settings tree: a folder as a disclosure group with its
/// children nested inside, or a link with its address and a remove button.
private struct BookmarkSettingsRow: View {
    let node: BookmarkNode
    @ObservedObject var store: BookmarkStore
    @State private var isExpanded = true

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(store.children(of: node.id)) { child in
                    BookmarkSettingsRow(node: child, store: store)
                }
            } label: {
                rowBody
            }
            .padding(.vertical, 2)
        } else {
            rowBody
                .padding(.vertical, 6)
        }
    }

    private var rowBody: some View {
        HStack(spacing: 10) {
            Image(systemName: node.isFolder ? "folder" : "bookmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if let url = node.url, !url.isEmpty {
                    Text(url)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button {
                store.delete(node.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(
                node.isFolder
                    ? "Remove this folder and everything in it"
                    : "Remove this bookmark"
            )
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

            SettingsGroup(
                title: "Result Links",
                footnote: "Stops search engines swapping result links for tracker hops when you press them. Active on supported result pages only."
            ) {
                SettingsToggleRow(
                    title: "Clean search result links",
                    subtitle: "Clicks and copied links carry the destination.",
                    isOn: store.binding(\.search.cleanResultLinks)
                )
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

            // Toggled in place, inside this section: the form belongs to
            // these engines, not after whatever group follows.
            if isAdding {
                Divider()
                addForm
            }
        }
    }

    /// The add form, shown in place rather than as a dialog.
    ///
    /// In place keeps the validation message next to the field it is about, which
    /// is the whole reason to show it at all.
    private var addForm: some View {
        VStack(alignment: .leading, spacing: 2) {
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
            // Same height as the master password inputs: rounded border at
            // large control size, so every text input in Settings matches.
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
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
    @StateObject private var store = DownloadsStore()
    @State private var isConfirmingClear = false

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: "Location",
                footnote: "Every download lands here. Filenames de-duplicate automatically, so nothing is ever overwritten."
            ) {
                SettingsButtonRow(
                    title: "Download folder",
                    subtitle: DownloadsCenter.downloadsDirectory.path
                ) {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([DownloadsCenter.downloadsDirectory])
                    }
                    .controlSize(.small)
                }
            }

            SettingsGroup(
                title: "Storage",
                footnote: "History rows point at files on disk. Clearing forgets the rows; files stay where they are."
            ) {
                SettingsButtonRow(
                    title: "Download history",
                    subtitle: store.items.isEmpty ? "No downloads yet" : "\(store.items.count) items"
                ) {
                    EmptyView()
                }
                if isConfirmingClear {
                    Text("Forget every download row?")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        Button("Cancel") {
                            isConfirmingClear = false
                        }
                        .controlSize(.small)
                        Button("Clear everything", role: .destructive) {
                            isConfirmingClear = false
                            Task { await store.clear() }
                        }
                        .controlSize(.small)
                    }
                } else {
                    SettingsButtonRow(
                        title: "Clear history",
                        subtitle: "Forget all download rows."
                    ) {
                        Button("Clear", role: .destructive) {
                            isConfirmingClear = true
                        }
                        .controlSize(.small)
                        .disabled(store.items.isEmpty)
                    }
                }
            }
        }
        .task {
            await DownloadsCenter.shared.reconcileInterrupted()
            store.load()
        }
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