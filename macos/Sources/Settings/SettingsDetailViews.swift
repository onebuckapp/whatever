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

/// One language picker option: the settings tag (`system`, following the
/// system locale, or a shipped BCP-47 tag like `ro`).
struct LanguageOption: Hashable, Identifiable {
    let tag: String
    var id: String { tag }
}

struct GeneralSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    // Observed for `revision`: a language switch re-renders every migrated
    // literal below without a relaunch.
    @ObservedObject private var localization = Localization.shared
    @StateObject private var defaultBrowser = DefaultBrowserSettings()
    @StateObject private var updater = AppUpdateSettings()
    @State private var shippedLanguages: [String] = []

    /// Picker options: System first, then every shipped translation tag.
    private var languageOptions: [LanguageOption] {
        [LanguageOption(tag: "system")] + shippedLanguages.map(LanguageOption.init(tag:))
    }

    private var languageSelection: Binding<LanguageOption> {
        Binding(
            get: { LanguageOption(tag: store.settings.general.language) },
            set: { store.binding(\.general.language).wrappedValue = $0.tag }
        )
    }

    private func languageLabel(for option: LanguageOption) -> String {
        option.tag == "system"
            ? tr("System", ctx: "Settings.General")
            : Localization.displayName(for: option.tag)
    }

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: tr("Software Update", ctx: "Settings.General"),
                footnote: tr("Whatever never updates itself. Checking asks GitHub for the latest release; downloading fetches its disk image for this Mac, and updating from it stays in your hands.", ctx: "Settings.General")
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
                title: tr("Default Browser", ctx: "Settings.General"),
                footnote: tr("Links clicked in other apps open here.", ctx: "Settings.General")
            ) {
                SettingsButtonRow(
                    title: defaultBrowser.isDefault
                        ? tr("Whatever is your default browser", ctx: "Settings.General")
                        : tr("Whatever is not your default browser", ctx: "Settings.General"),
                    subtitle: defaultBrowser.isDefault
                        ? tr("This Mac already opens web links in Whatever.", ctx: "Settings.General")
                        : tr("Claim http and https links from your current browser.", ctx: "Settings.General")
                ) {
                    if !defaultBrowser.isDefault {
                        Button(tr("Set Whatever as Default Browser", ctx: "Settings.General")) {
                            Task { await defaultBrowser.makeDefault() }
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsGroup(
                title: tr("Session", ctx: "Settings.General"),
                footnote: tr("Restoring reopens the previous window's tabs.", ctx: "Settings.General")
            ) {
                SettingsToggleRow(
                    title: tr("Restore last session", ctx: "Settings.General"),
                    subtitle: tr("Reopen the previous window's tabs at launch.", ctx: "Settings.General"),
                    isOn: store.binding(\.general.restoreSession)
                )
            }

            SettingsGroup(
                title: tr("Quitting", ctx: "Settings.General"),
                footnote: tr("The second press quits at once, even with windows open.", ctx: "Settings.General")
            ) {
                SettingsToggleRow(
                    title: tr("Confirm before quitting", ctx: "Settings.General"),
                    subtitle: tr("First ⌘Q shows a prompt; press ⌘Q again to quit.", ctx: "Settings.General"),
                    isOn: store.binding(\.general.warnBeforeQuitting)
                )
            }

            SettingsGroup(
                title: tr("History", ctx: "Settings.General"),
                footnote: tr("Private tabs are never recorded, whatever this says.", ctx: "Settings.General")
            ) {
                SettingsToggleRow(
                    title: tr("Record visited pages", ctx: "Settings.General"),
                    subtitle: tr("Adds committed main-frame visits to history.", ctx: "Settings.General"),
                    isOn: store.binding(\.general.recordsHistory)
                )
                SettingsSliderRow(
                    title: tr("Collapse repeats within", ctx: "Settings.General"),
                    value: store.binding(\.general.historyCollapseWindow),
                    range: 0...120,
                    step: 1,
                    format: { String(format: "%.0f s", $0) }
                )
            }

            SettingsGroup(
                title: tr("Language", ctx: "Settings.General"),
                footnote: tr("The interface language. Translated text switches right away.", ctx: "Settings.General")
            ) {
                SettingsPickerRow(
                    title: tr("Language", ctx: "Settings.General"),
                    options: languageOptions,
                    selection: languageSelection,
                    label: languageLabel(for:)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { defaultBrowser.refresh() }
        .task { shippedLanguages = await Localization.shippedTags() }
        .onChange(of: store.settings.general.language) {
            Task {
                await Localization.shared.refresh()
                // The same Task that swaps the table re-applies the
                // AppKit-owned bar titles: they do not follow the revision
                // tick (or the change notification) on their own.
                MenuBarRetitler.retitleBar()
            }
        }
    }

    /// The update row's trailing control under `updater.status`: a check
    /// button at rest, a spinner while busy, the download button when an
    /// update is ready, and a Finder reveal once it has landed.
    @ViewBuilder
    private var updateAccessory: some View {
        switch updater.status {
        case .idle, .upToDate, .failed, .noCompatibleDownload:
            Button(tr("Check for Updates", ctx: "Settings.General")) {
                Task { await updater.checkForUpdates() }
            }
            .controlSize(.small)
        case .checking, .downloading:
            ProgressView()
                .controlSize(.small)
        case .available:
            Button(tr("Download Update", ctx: "Settings.General")) {
                Task { await updater.downloadUpdate() }
            }
            .controlSize(.small)
        case .downloaded:
            Button(tr("Show in Finder", ctx: "Settings.General")) {
                updater.revealDownload()
            }
            .controlSize(.small)
        }
    }
}

/// The app icon for SwiftUI, retina-sharp at any point size.
///
/// Two traps, both taken: `Image(nsImage:)` on the raw app icon snapshots
/// at point resolution (soft on retina), and adding `.resizable()` keeps it
/// soft — the image is rasterized once at 1x and upscaled, ignoring any
/// extra representations. So the icon is rasterized up front with explicit
/// 1x/2x/3x bitmaps at the requested size and drawn without `.resizable()`,
/// which is what lets the renderer pick the 2x bitmap on a retina screen.
/// (An `NSImageView` representable was tried between the two and cropped:
/// the 512pt intrinsic size won over the frame.)
struct AppIconView: View {
    var points: CGFloat = 32

    var body: some View {
        Image(nsImage: Self.iconImage(points: points))
            .frame(width: points, height: points)
    }

    /// First touched from a body, so always on the main thread.
    static var iconImage: NSImage { iconImage(points: 32) }

    static func iconImage(points: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points))
        // Nil in principle (no icon set); then this stays a blank image
        // rather than crashing the pane.
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
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @ObservedObject private var grain = NoiseOverlaySettings.shared
    @State private var filter = ""
    @State private var confirmingReset = false

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
                if matches("Reset Appearance", "reset restore defaults factory built-in appearance") {
                    resetGroup
                }
                if !filter.isEmpty, !hasAnyMatch {
                    Text(tr("No settings match {query}.", ctx: "Settings.Appearance", args: ["query": "“\(filter.trimmingCharacters(in: .whitespacesAndNewlines))”"]))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(tr("Reset appearance settings?", ctx: "Settings.Appearance"), isPresented: $confirmingReset) {
            Button(tr("Reset", ctx: "Settings.Appearance"), role: .destructive) {
                resetAppearance()
            }
            Button(tr("Cancel", ctx: "Settings.Appearance"), role: .cancel) {}
        } message: {
            Text(tr("Are you sure? Grain, background, tab theme, and address bar return to their built-in defaults.", ctx: "Settings.Appearance"))
        }
    }

    /// Pinned above the scrolling groups: typing narrows the pane to the
    /// matching sections, clearing restores everything.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField(tr("Filter settings", ctx: "Settings.Appearance"), text: $filter)
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
            || matches("Reset Appearance", "reset restore defaults factory built-in appearance")
    }

    private var grainGroup: some View {
        SettingsGroup(
            title: tr("Grain", ctx: "Settings.Appearance"),
            footnote: tr("A film-grain texture over the whole window. Every change applies as you make it.", ctx: "Settings.Appearance")
        ) {
            SettingsToggleRow(
                title: tr("Enabled", ctx: "Settings.Appearance"),
                subtitle: tr("Hides the texture without losing these settings.", ctx: "Settings.Appearance"),
                isOn: grain.enabledBinding
            )
            SettingsButtonRow(
                title: tr("New pattern", ctx: "Settings.Appearance"),
                subtitle: tr("Same settings, different grain.", ctx: "Settings.Appearance")
            ) {
                Button(tr("Generate", ctx: "Settings.Appearance")) {
                    grain.rerollSeed()
                }
                .controlSize(.small)
            }
            SettingsButtonRow(
                title: tr("Reset", ctx: "Settings.Appearance"),
                subtitle: tr("Back to the built-in grain.", ctx: "Settings.Appearance")
            ) {
                Button(tr("Reset", ctx: "Settings.Appearance")) {
                    grain.reset()
                }
                .controlSize(.small)
            }
        }
    }

    private var lookGroup: some View {
        SettingsGroup(
            title: tr("Look", ctx: "Settings.Appearance"),
            isEnabled: grain.configuration.isEnabled
        ) {
            SettingsPickerRow(
                title: tr("Color", ctx: "Settings.Appearance"),
                options: GrainColorMode.allCases,
                selection: grain.colorModeBinding,
                isSegmented: true,
                label: { $0.title }
            )
            SettingsSliderRow(
                title: tr("Opacity", ctx: "Settings.Appearance"),
                value: grain.opacityBinding,
                range: 0...0.5,
                step: 0.05,
                format: { String(format: "%.2f", $0) }
            )
            SettingsSliderRow(
                title: tr("Intensity", ctx: "Settings.Appearance"),
                value: grain.intensityBinding,
                range: 0...1,
                step: 0.05,
                format: { String(format: "%.2f", $0) }
            )
            SettingsSliderRow(
                title: tr("Contrast", ctx: "Settings.Appearance"),
                value: grain.contrastBinding,
                range: 1...8,
                step: 0.1,
                format: { String(format: "%.1f", $0) }
            )
            SettingsSliderRow(
                title: tr("Grain Size", ctx: "Settings.Appearance"),
                value: grain.grainScaleBinding,
                range: 1...4,
                step: 0.1,
                format: { String(format: "%.1f×", $0) }
            )
        }
    }

    private var resetGroup: some View {
        SettingsGroup(
            title: tr("Reset Appearance", ctx: "Settings.Appearance"),
            footnote: tr("Restores every setting on this page — grain, background, tab theme, and address bar — to its built-in default.", ctx: "Settings.Appearance")
        ) {
            SettingsButtonRow(
                title: tr("Reset appearance settings", ctx: "Settings.Appearance"),
                subtitle: tr("Back to the built-in look.", ctx: "Settings.Appearance")
            ) {
                Button(tr("Reset…", ctx: "Settings.Appearance")) {
                    confirmingReset = true
                }
                .controlSize(.small)
            }
        }
    }

    /// Restores the pane through the store, then the grain overlay's
    /// in-memory copy, which mirrors the store rather than reading it.
    /// The grain persist lands on already-default noise, so the store's
    /// change detection swallows it and nothing saves twice.
    private func resetAppearance() {
        SettingsStore.shared.resetAppearance()
        grain.reset()
    }
}

    // MARK: - Web

struct WebSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: tr("Pages", ctx: "Settings.Web"),
                footnote: Self.effect(of: [\AppSettings.WebSettings.allowsJavaScript])
            ) {
                SettingsToggleRow(
                    title: tr("Allow JavaScript", ctx: "Settings.Web"),
                    subtitle: tr("Off blocks scripts, which also stops most sites from working.", ctx: "Settings.Web"),
                    isOn: store.binding(\.web.allowsJavaScript)
                )
                SettingsToggleRow(
                    title: tr("Upgrade known hosts to HTTPS", ctx: "Settings.Web"),
                    isOn: store.binding(\.web.upgradeKnownHostsToHTTPS)
                )
                SettingsToggleRow(
                    title: tr("JavaScript may open windows", ctx: "Settings.Web"),
                    subtitle: tr("Lets a page open a tab without a click. Popups land in this window.", ctx: "Settings.Web"),
                    isOn: store.binding(\.web.javaScriptCanOpenWindowsAutomatically)
                )
            }

            SettingsGroup(
                title: tr("Media", ctx: "Settings.Web"),
                footnote: Self.effect(of: [\AppSettings.WebSettings.mediaAutoplay])
            ) {
                SettingsPickerRow(
                    title: tr("Play without a click", ctx: "Settings.Web"),
                    options: AppSettings.MediaAutoplayPolicy.allCases,
                    selection: store.binding(\.web.mediaAutoplay),
                    label: Self.autoplayLabel
                )
            }

            SettingsGroup(
                title: tr("Privacy", ctx: "Settings.Web"),
                footnote: Self.effect(of: [
                    \AppSettings.WebSettings.fraudulentWebsiteWarningEnabled,
                    \AppSettings.WebSettings.siteSpecificQuirksModeEnabled,
                ])
            ) {
                SettingsToggleRow(
                    title: tr("Fraudulent website warnings", ctx: "Settings.Web"),
                    isOn: store.binding(\.web.fraudulentWebsiteWarningEnabled)
                )
                SettingsToggleRow(
                    title: tr("Site-specific quirks mode", ctx: "Settings.Web"),
                    isOn: store.binding(\.web.siteSpecificQuirksModeEnabled)
                )
            }

            SettingsGroup(
                title: tr("Display", ctx: "Settings.Web"),
                footnote: Self.effect(of: [
                    \AppSettings.WebSettings.pageZoom,
                    \AppSettings.WebSettings.minimumFontSize,
                ])
            ) {
                SettingsSliderRow(
                    title: tr("Page zoom", ctx: "Settings.Web"),
                    value: store.binding(\.web.pageZoom),
                    range: 0.5...3,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsSliderRow(
                    title: tr("Minimum font size", ctx: "Settings.Web"),
                    value: store.binding(\.web.minimumFontSize),
                    range: 0...24,
                    step: 1,
                    format: { $0 == 0 ? tr("off", ctx: "Settings.Web") : String(format: "%.0f pt", $0) }
                )
            }

            SettingsGroup(title: tr("Interaction", ctx: "Settings.Web")) {
                SettingsToggleRow(
                    title: tr("Back/forward gestures", ctx: "Settings.Web"),
                    isOn: store.binding(\.web.allowsBackForwardNavigationGestures)
                )
                SettingsToggleRow(
                    title: tr("Magnification", ctx: "Settings.Web"),
                    isOn: store.binding(\.web.allowsMagnification)
                )
                SettingsToggleRow(
                    title: tr("Link previews", ctx: "Settings.Web"),
                    isOn: store.binding(\.web.allowsLinkPreview)
                )
                SettingsToggleRow(
                    title: tr("Tab focuses links", ctx: "Settings.Web"),
                    isOn: store.binding(\.web.tabFocusesLinks)
                )
            }

            SettingsGroup(
                title: tr("Sleeping tabs", ctx: "Settings.Web"),
                // Hand-written rather than the derived engine footnote: this
                // is app behaviour, not a WebKit property, and neither
                // "applies immediately" nor "needs a new page" describes a
                // minute-cadence reaper.
                footnote: tr("Hidden tabs past this idle time lose their page and free its memory. Showing one reloads its address; displayed, pinned, sounding, and loading tabs never sleep.", ctx: "Settings.Web")
            ) {
                SettingsPickerRow(
                    title: tr("Sleep unused tabs", ctx: "Settings.Web"),
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
            return tr("Applies to open pages immediately.", ctx: "Settings.Web")
        }
        if needsNewPage == keyPaths.count {
            return tr("Read when a page is opened. Changes take effect on the next page.", ctx: "Settings.Web")
        }
        return tr("Some of these take effect on the next page.", ctx: "Settings.Web")
    }

    private static func autoplayLabel(_ policy: AppSettings.MediaAutoplayPolicy) -> String {
        switch policy {
        case .never: tr("Nothing", ctx: "Settings.Web")
        case .video: tr("Video", ctx: "Settings.Web")
        case .audio: tr("Audio", ctx: "Settings.Web")
        case .all: tr("Everything", ctx: "Settings.Web")
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
                tr("Show bookmarks bar", ctx: "Settings.Bookmarks"),
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
            Text(tr("Bookmarks", ctx: "Settings.Bookmarks"))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(tr("Remove All", ctx: "Settings.Bookmarks")) {
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
                title: tr("Bookmarks unavailable", ctx: "Settings.Bookmarks"),
                message: failure
            )
        } else if store.nodes.isEmpty {
            SettingsPlaceholder(
                symbol: "bookmark",
                title: tr("No bookmarks yet", ctx: "Settings.Bookmarks"),
                message: tr("Bookmarks you add will be listed here.", ctx: "Settings.Bookmarks")
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
                    ? tr("Remove this folder and everything in it", ctx: "Settings.Bookmarks")
                    : tr("Remove this bookmark", ctx: "Settings.Bookmarks")
            )
        }
    }
}

// MARK: - History

struct HistorySettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    // Observed for `revision`: visit-count labels re-resolve below without
    // reopening Settings.
    @ObservedObject private var localization = Localization.shared
    @State private var entries: [HistoryEntry] = []
    @State private var isLoading = true
    /// Finished "N visits" labels by entry id, resolved core-side (plural
    /// form selection cannot happen in a synchronous row).
    @State private var visitLabels: [String: String] = [:]

    var body: some View {
        list
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await load() }
            .onChange(of: store.settings.general.recordsHistory) {
                Task { await load() }
            }
            .onChange(of: localization.revision) {
                Task { await resolveVisitLabels() }
            }
    }

    private var header: some View {
        HStack {
            Text(tr("History", ctx: "Settings.History"))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(tr("Delete Older Than 30 Days", ctx: "Settings.History")) {
                Task { await deleteOlderThan() }
            }
            .controlSize(.small)
            .disabled(isLoading)
            Button(tr("Clear All", ctx: "Settings.History")) {
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
                title: tr("Record visited pages", ctx: "Settings.History"),
                subtitle: tr("Private tabs are never recorded, whatever this says.", ctx: "Settings.History"),
                isOn: store.binding(\.general.recordsHistory)
            )
            SettingsSliderRow(
                title: tr("Collapse repeats within", ctx: "Settings.History"),
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
                title: tr("No history yet", ctx: "Settings.History"),
                message: tr("Pages you visit show up here.", ctx: "Settings.History")
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
            Text(visitLabels[entry.id] ?? "")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Button {
                Task { await remove(entry) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(tr("Remove this entry", ctx: "Settings.History"))
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
        await resolveVisitLabels()
    }

    /// One batch call resolves every visible "N visits" label, in order.
    /// Single-visit rows keep no label, exactly as before.
    private func resolveVisitLabels() async {
        let counted = entries.filter { $0.visitCount > 1 }
        guard !counted.isEmpty else {
            visitLabels = [:]
            return
        }
        let items = counted.map { entry in
            LocaleItem("one visit", plural: "{n} visits", n: entry.visitCount)
        }
        let texts = await Localization.batch(items)
        var labels: [String: String] = [:]
        for (offset, entry) in counted.enumerated() where offset < texts.count {
            labels[entry.id] = texts[offset]
        }
        visitLabels = labels
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
    /// Tab order through the add form: without explicit focus bindings
    /// SwiftUI leaves Tab dead inside the hosted card, and without a bound
    /// focus state the fields take the cold focus path. Same arrangement as
    /// the window-size card's form.
    enum EngineField: Hashable {
        case name, address, queryItem
    }

    @ObservedObject private var store = SettingsStore.shared
    @State private var isAdding = false
    @State private var draft = CustomSearchEngine()
    @FocusState private var focusedField: EngineField?
    @State private var tabMonitor: Any?

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: tr("Default Engine", ctx: "Settings.Search"),
                footnote: tr("What the address field sends a search to. Anything that looks like a web address still loads directly.", ctx: "Settings.Search")
            ) {
                ForEach(PredefinedSearchEngine.allCases) { engine in
                    SettingsRadioRow(
                        title: engine.title,
                        subtitle: engine.isPrivate ? nil : tr("Records what you search for", ctx: "Settings.Search"),
                        isSelected: store.settings.search.isSelected(engine.rawValue)
                    ) {
                        select(engine.rawValue)
                    }
                }
            }

            customGroup

            SettingsGroup(
                title: tr("Result Links", ctx: "Settings.Search"),
                footnote: tr("Stops search engines swapping result links for tracker hops when you press them. Active on supported result pages only.", ctx: "Settings.Search")
            ) {
                SettingsToggleRow(
                    title: tr("Clean search result links", ctx: "Settings.Search"),
                    subtitle: tr("Clicks and copied links carry the destination.", ctx: "Settings.Search"),
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
            title: tr("Your Engines", ctx: "Settings.Search"),
            footnote: store.settings.search.customEngines.isEmpty
                ? tr("Add an engine to search somewhere these do not go.", ctx: "Settings.Search")
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
                    .help(tr("Remove this engine", ctx: "Settings.Search"))
                }
            }

            SettingsButtonRow(
                title: tr(isAdding ? "Cancel" : "Add Engine", ctx: "Settings.Search"),
                subtitle: tr("An address, and the query parameter it takes.", ctx: "Settings.Search")
            ) {
                Button(tr(isAdding ? "Cancel" : "Add", ctx: "Settings.Search")) {
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
            labelledField(tr("Name", ctx: "Settings.Search"), text: $draft.name, placeholder: tr("My search", ctx: "Settings.Search"), field: .name)
            labelledField(tr("Address", ctx: "Settings.Search"), text: $draft.address, placeholder: "https://example.com/search", field: .address)
            labelledField(tr("Query parameter", ctx: "Settings.Search"), text: $draft.queryItem, placeholder: "q", field: .queryItem)

            if let problem {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(tr("Cancel", ctx: "Settings.Search")) {
                    isAdding = false
                }
                .controlSize(.small)
                Button(tr("Save", ctx: "Settings.Search")) {
                    add()
                }
                .controlSize(.small)
                .disabled(problem != nil)
            }
        }
        // The caret starts in the name field: typed-first, no click needed,
        // and the focus infra is warm before any click lands. Delayed
        // because the pane mounts asynchronously and a focus set before the
        // field exists is silently dropped — same cadence as the
        // window-size card.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            focusedField = .name
            try? await Task.sleep(for: .milliseconds(200))
            if focusedField == nil {
                focusedField = .name
            }
        }
        .onAppear {
            // Tab and Shift+Tab walk the three fields explicitly. The
            // fields' AppKit editor eats Tab before SwiftUI's focus engine
            // sees it, so bindings alone leave Tab dead: this monitor runs
            // first and swallows only Tabs pressed while this form holds
            // focus, so Tab anywhere else in the window is untouched.
            guard tabMonitor == nil else { return }
            let focus = $focusedField
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 48 else { return event }
                let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
                guard mods == [] || mods == [.shift] else { return event }
                return MainActor.assumeIsolated { () -> NSEvent? in
                    guard focus.wrappedValue != nil else { return event }
                    let forward = !mods.contains(.shift)
                    focus.wrappedValue = forward
                        ? Self.nextField(after: focus.wrappedValue)
                        : Self.previousField(before: focus.wrappedValue)
                    return nil
                }
            }
        }
        .onDisappear {
            if let monitor = tabMonitor {
                NSEvent.removeMonitor(monitor)
                tabMonitor = nil
            }
        }
    }

    /// Next field walking forward with wraparound, or nil stays nil: Tab
    /// with no field focused is not this form's to swallow. Static so the
    /// walk is testable without a pane or any key events.
    static func nextField(after field: EngineField?) -> EngineField? {
        switch field {
        case .name: .address
        case .address: .queryItem
        case .queryItem: .name
        case nil: nil
        }
    }

    static func previousField(before field: EngineField?) -> EngineField? {
        switch field {
        case .name: .queryItem
        case .address: .name
        case .queryItem: .address
        case nil: nil
        }
    }

    private func labelledField(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        field: EngineField
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
            // Same height as the master password inputs: rounded border at
            // large control size, so every text input in Settings matches.
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focusedField, equals: field)
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
    // Observed for `revision`: the count summary re-resolves below without
    // reopening Settings.
    @ObservedObject private var localization = Localization.shared
    @State private var isConfirmingClear = false
    /// Finished "N downloads" subtitle, resolved core-side: plural form
    /// selection cannot happen in a synchronous row.
    @State private var itemSummary = ""

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: tr("Location", ctx: "Settings.Downloads"),
                footnote: tr("Every download lands here. Filenames de-duplicate automatically, so nothing is ever overwritten.", ctx: "Settings.Downloads")
            ) {
                SettingsButtonRow(
                    title: tr("Download folder", ctx: "Settings.Downloads"),
                    subtitle: DownloadsCenter.downloadsDirectory.path
                ) {
                    Button(tr("Reveal", ctx: "Settings.Downloads")) {
                        NSWorkspace.shared.activateFileViewerSelecting([DownloadsCenter.downloadsDirectory])
                    }
                    .controlSize(.small)
                }
            }

            SettingsGroup(
                title: tr("Storage", ctx: "Settings.Downloads"),
                footnote: tr("History rows point at files on disk. Clearing forgets the rows; files stay where they are.", ctx: "Settings.Downloads")
            ) {
                SettingsButtonRow(
                    title: tr("Download history", ctx: "Settings.Downloads"),
                    subtitle: itemSummary
                ) {
                    EmptyView()
                }
                if isConfirmingClear {
                    Text(tr("Forget every download row?", ctx: "Settings.Downloads"))
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        Button(tr("Cancel", ctx: "Settings.Downloads")) {
                            isConfirmingClear = false
                        }
                        .controlSize(.small)
                        Button(tr("Clear everything", ctx: "Settings.Downloads"), role: .destructive) {
                            isConfirmingClear = false
                            Task { await store.clear() }
                        }
                        .controlSize(.small)
                    }
                } else {
                    SettingsButtonRow(
                        title: tr("Clear history", ctx: "Settings.Downloads"),
                        subtitle: tr("Forget all download rows.", ctx: "Settings.Downloads")
                    ) {
                        Button(tr("Clear", ctx: "Settings.Downloads"), role: .destructive) {
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
        .task(id: "\(store.items.count)-\(localization.revision)") {
            await resolveItemSummary()
        }
    }

    /// One batch call resolves the "N downloads" subtitle, in the row's own
    /// words for every count. Empty history reads as its own sentence.
    private func resolveItemSummary() async {
        let count = store.items.count
        guard count > 0 else {
            itemSummary = tr("No downloads yet", ctx: "Settings.Downloads")
            return
        }
        let texts = await Localization.batch([
            LocaleItem("one download", plural: "{n} downloads", n: count),
        ])
        itemSummary = texts.first ?? "\(count) downloads"
    }
}

// MARK: - Content Blocker

struct ContentBlockerSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var blocker = ContentBlockerStore.shared
    // Observed for `revision`: the stat summaries re-resolve below without
    // reopening Settings.
    @ObservedObject private var localization = Localization.shared
    @State private var rulesDraft = ""
    @State private var rulesSeeded = false
    @State private var hostDraft = ""
    /// Finished stat subtitles, resolved core-side in one batch call:
    /// plural form selection cannot happen in synchronous rows.
    @State private var snapshotSummary = ""
    @State private var rulesSummary = ""
    @State private var skippedSummary = ""

    private var exceptions: [String] {
        store.settings.adblock.exceptions.sorted()
    }

    var body: some View {
        SettingsDetailStack {
            SettingsGroup(
                title: tr("Blocking", ctx: "Settings.Blocker"),
                footnote: tr("Pages reload to pick up a change.", ctx: "Settings.Blocker")
            ) {
                SettingsToggleRow(
                    title: tr("Block ads and trackers", ctx: "Settings.Blocker"),
                    subtitle: tr("Third-party requests to listed hosts never leave the page.", ctx: "Settings.Blocker"),
                    isOn: store.binding(\.adblock.enabled)
                )
            }

            SettingsGroup(
                title: tr("Filter lists", ctx: "Settings.Blocker"),
                footnote: tr("Ships with the app. Nothing is downloaded and no browsing data leaves the machine: lists compile on device.", ctx: "Settings.Blocker")
            ) {
                SettingsButtonRow(
                    title: tr("Bundled snapshot", ctx: "Settings.Blocker"),
                    subtitle: snapshotSummary
                ) {
                    EmptyView()
                }
                SettingsButtonRow(
                    title: tr("Source", ctx: "Settings.Blocker"),
                    subtitle: tr("AdAway default blocklist · CC BY 3.0 · plus our own extras", ctx: "Settings.Blocker")
                ) {
                    EmptyView()
                }
                if blocker.lastMeta != nil {
                    SettingsButtonRow(
                        title: tr("Rules", ctx: "Settings.Blocker"),
                        subtitle: rulesSummary
                    ) {
                        EmptyView()
                    }
                    SettingsButtonRow(
                        title: tr("Skipped lines", ctx: "Settings.Blocker"),
                        subtitle: skippedSummary
                    ) {
                        EmptyView()
                    }
                }
                if let error = blocker.lastError {
                    SettingsButtonRow(
                        title: tr("Last error", ctx: "Settings.Blocker"),
                        subtitle: error
                    ) {
                        EmptyView()
                    }
                }
            }

            SettingsGroup(
                title: tr("Custom rules", ctx: "Settings.Blocker"),
                footnote: tr("Hosts lines plus ||, @@ and ## rules, one per line. Applied together with the snapshot.", ctx: "Settings.Blocker")
            ) {
                TextEditor(text: $rulesDraft)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 120)
                HStack {
                    Spacer(minLength: 0)
                    Button(tr("Apply rules", ctx: "Settings.Blocker")) { applyRules() }
                        .controlSize(.small)
                }
            }

            SettingsGroup(
                title: tr("Exceptions", ctx: "Settings.Blocker"),
                footnote: tr("Sites the blocker leaves alone, subdomains included.", ctx: "Settings.Blocker")
            ) {
                if exceptions.isEmpty {
                    Text(tr("No exceptions.", ctx: "Settings.Blocker"))
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
                            .accessibilityLabel(tr("Remove {host}", ctx: "Settings.Blocker", args: ["host": host]))
                        }
                        .padding(.vertical, 3)
                    }
                }
                HStack {
                    TextField("example.com", text: $hostDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { add() }
                    Button(tr("Add", ctx: "Settings.Blocker"), action: add)
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
        .task(id: "\(statSignature)-\(localization.revision)") {
            await resolveStatSummaries()
        }
    }

    /// Everything the stat rows show, so one batch call refreshes them
    /// together whenever the fingerprint or the language moves.
    private var statSignature: String {
        let meta = blocker.lastMeta
        return [
            store.settings.adblock.snapshotVersion ?? "",
            "\(meta?.ruleCount ?? -1)",
            "\(meta?.blockCount ?? -1)",
            "\(meta?.cosmeticCount ?? -1)",
            "\(meta?.exceptionCount ?? -1)",
            "\(meta?.skippedLines ?? -1)",
        ].joined(separator: "|")
    }

    /// One batch call resolves the snapshot, rules, and skipped-lines
    /// subtitles in the row's own words for every count. Joined
    /// client-side around opaque values, exactly like the English text.
    private func resolveStatSummaries() async {
        let version = store.settings.adblock.snapshotVersion ?? "—"
        let meta = blocker.lastMeta
        let texts = await Localization.batch([
            LocaleItem("one rule", plural: "{n} rules", n: meta?.ruleCount ?? 0),
            LocaleItem("one host", plural: "{n} hosts", n: meta?.blockCount ?? 0),
            LocaleItem("one cosmetic rule", plural: "{n} cosmetic rules", n: meta?.cosmeticCount ?? 0),
            LocaleItem("one exception", plural: "{n} exceptions", n: meta?.exceptionCount ?? 0),
            LocaleItem(
                "one line the compiler ignored",
                plural: "{n} lines the compiler ignored",
                n: meta?.skippedLines ?? 0
            ),
        ])
        guard texts.count == 5 else { return }
        snapshotSummary = "\(version) · \(texts[0])"
        rulesSummary = "\(texts[1]) · \(texts[2]) · \(texts[3])"
        skippedSummary = texts[4]
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