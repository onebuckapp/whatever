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

import Combine
import Foundation

/// Owns the theme stylesheets: the managed block regenerated from the
/// Appearance controls, the user's hand-written block from settings, and
/// cascade resolution over the chrome node trees.
///
/// The full CSS (`managed + customCSS`) is published; each chrome region
/// (tab strip, toolbar, page, crawl bar, background) resolves its own tiny
/// node tree against it when its states change, and overlays the winners
/// after its structured theme. Resolution is stateless and fail-open — a
/// failed call resolves to no overrides, never to an error state — so the
/// structured theme always stands alone when CSS is absent or broken.
@MainActor
final class ThemeEngine: ObservableObject {
    static let shared = ThemeEngine()

    /// Managed CSS plus the user's `customCSS`, the single source every
    /// region resolves against.
    @Published private(set) var fullCSS = ""
    /// The managed block alone, for the editor preview.
    @Published private(set) var managedCSS = ""

    private var generation = 0
    private var cachedSpec: Data?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        SettingsStore.shared.$settings
            .map { settings in
                [
                    String(describing: settings.appearance),
                    String(describing: settings.addressBar),
                    String(describing: settings.feeds.crawlBackgroundOpacity),
                    settings.appearance.customCSS,
                ]
            }
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshManaged() }
            }
            .store(in: &cancellables)
        Task { await refreshManaged() }
    }

    /// Rebuilds the managed block from the current settings and republishes
    /// the full CSS. Called on settings ticks (debounced) and directly after
    /// a control writes, so the editor never shows a stale managed block.
    func refreshManaged() async {
        generation += 1
        let current = generation
        let document = Self.managedDocument()
        guard let json = try? JSONSerialization.data(withJSONObject: document),
              let text = String(data: json, encoding: .utf8)
        else { return }
        let managed: String
        do {
            let data = try await StoreClient.shared.themeSerialize(styles: text)
            guard current == generation else { return }
            managed = String(data: data, encoding: .utf8) ?? ""
        } catch {
            guard current == generation else { return }
            managed = ""
        }
        managedCSS = managed
        publishFullCSS()
    }

    /// Re-resolves when the user block changes without touching the managed
    /// one (the editor calls this on Apply).
    func refreshUserCSS() {
        publishFullCSS()
    }

    private func publishFullCSS() {
        let custom = SettingsStore.shared.settings.appearance.customCSS
        let combined: String
        if custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combined = managedCSS
        } else if managedCSS.isEmpty {
            combined = custom
        } else {
            combined = managedCSS + "\n" + custom
        }
        if combined != fullCSS {
            fullCSS = combined
        }
    }

    /// Runs the cascade over `nodes` against the current full CSS. Returns
    /// no overrides when there is no CSS or the call fails: the structured
    /// theme is always the floor, CSS only ever overlays.
    func resolve(nodes: [ThemeNode]) async -> [String: [String: String]] {
        let css = fullCSS
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document = ThemeNode.document(nodes)
        else { return [:] }
        do {
            let data = try await StoreClient.shared.themeResolve(css: css, nodes: document)
            return ThemeNode.styles(from: data)
        } catch {
            return [:]
        }
    }

    /// The supported surface (`bc_theme_spec`), cached for the session: the
    /// editor help and instant feedback read this instead of hardcoding it.
    func spec() async -> Data? {
        if let cachedSpec { return cachedSpec }
        do {
            let data = try await StoreClient.shared.themeSpec()
            cachedSpec = data
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Managed projection

    /// Projects the CSS-expressible slice of the structured settings onto
    /// `{selector: {property: raw-value}}` for `bc_theme_serialize`. Only
    /// simple values project: gradients with positions, images, and videos
    /// have no CSS counterpart and stay structured-only (their views still
    /// render them; the managed block simply does not mention them).
    static func managedDocument() -> [String: [String: String]] {
        let settings = SettingsStore.shared.settings
        var document: [String: [String: String]] = [:]
        var tab: [String: String] = [:]
        projectTabTheme(settings.appearance.tabTheme, into: &tab)
        tab["border-radius"] = cssPoints(settings.appearance.tabCornerRadius)
        if !tab.isEmpty { document[".tab"] = tab }
        var active: [String: String] = [:]
        projectTabTheme(settings.appearance.activeTabTheme, into: &active)
        active["border-radius"] = cssPoints(settings.appearance.tabCornerRadius)
        if !active.isEmpty { document[".tab:active"] = active }
        document["#addressbar"] = [
            "border-radius": cssPoints(settings.addressBar.cornerRadius)
        ]
        document["#crawlbar"] = [
            "opacity": String(settings.feeds.crawlBackgroundOpacity),
            "border-radius": cssPoints(settings.appearance.crawlCornerRadius),
        ]
        document["#page"] = [
            "border-radius": cssPoints(settings.appearance.pageCornerRadius)
        ]
        return document
    }

    private static func projectTabTheme(
        _ theme: TabThemeConfiguration,
        into props: inout [String: String]
    ) {
        switch theme.background.kind {
        case .solid:
            props["background-color"] = theme.background.solid.color.hexString
        case .gradient:
            if let css = cssGradient(theme.background.gradient) {
                props["background-image"] = css
            }
        case .none, .image, .video:
            break
        }
        if let foreground = theme.foreground {
            props["color"] = foreground.hexString
        }
    }

    private static func cssGradient(
        _ gradient: BackgroundMediaConfiguration.Gradient
    ) -> String? {
        guard gradient.kind == .linear, gradient.isUsable else { return nil }
        let stops = gradient.stops.map { $0.color.hexString }.joined(separator: ", ")
        return "linear-gradient(\(cssNumber(gradient.angle))deg, \(stops))"
    }

    private static func cssPoints(_ value: Double) -> String {
        cssNumber(value) + "px"
    }

    private static func cssNumber(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(value)
    }
}
