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
import Foundation

/// One supported, valid theme declaration from `bc_theme_declarations`:
/// what the editor's Apply maps back onto the Appearance controls.
struct ThemeDeclaration: Decodable {
    var selector: String
    var property: String
    var value: String
    var important: Bool
    var order: Int

    static func list(from data: Data) -> [ThemeDeclaration] {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return []
        }
        return document.declarations.sorted { $0.order < $1.order }
    }

    private struct Document: Decodable {
        var declarations: [ThemeDeclaration]
    }
}

/// Maps user-CSS declarations back onto the structured Appearance settings:
/// the controls side of the two-way sync. Only declarations with a real
/// control counterpart map; everything else stays live as a CSS-only
/// override through the cascade (counted, not dropped).
///
/// Safety rule: a declaration never destroys a richer structured value. A
/// `background-color` maps onto a none/solid tab background but leaves a
/// gradient, image, or video theme untouched — the CSS still applies as an
/// override, it just does not rewrite the controls.
@MainActor
enum ThemeCSSSync {
    struct Outcome {
        /// Declarations that landed on a control.
        var updated = 0
        /// Declarations that stay CSS-only overrides.
        var cssOnly = 0
    }

    static func apply(_ declarations: [ThemeDeclaration]) -> Outcome {
        var outcome = Outcome()
        SettingsStore.shared.update { settings in
            outcome = mapInto(declarations, &settings)
        }
        return outcome
    }

    /// Maps declarations into an in-out settings document, for callers that
    /// write more in the same update (the editor stores `customCSS`
    /// alongside the mapped controls so the two never save apart).
    static func mapInto(
        _ declarations: [ThemeDeclaration],
        _ settings: inout AppSettings
    ) -> Outcome {
        var outcome = Outcome()
        for declaration in declarations {
            if map(declaration, into: &settings) {
                outcome.updated += 1
            } else {
                outcome.cssOnly += 1
            }
        }
        return outcome
    }

    private static func map(
        _ declaration: ThemeDeclaration,
        into settings: inout AppSettings
    ) -> Bool {
        let selector = declaration.selector
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch (selector, declaration.property) {
        case (".tab", _), (".tab:active", _):
            return mapTabTheme(
                declaration, active: selector == ".tab:active",
                appearance: &settings.appearance)
        case ("#addressbar", "border-radius"):
            guard let radius = points(declaration.value) else { return false }
            settings.addressBar.cornerRadius = clamp(
                radius, AddressBarSettings.cornerRadiusRange)
            return true
        case ("#crawlbar", "opacity"):
            guard let opacity = Double(declaration.value) else { return false }
            settings.feeds.crawlBackgroundOpacity = min(max(opacity, 0), 1)
            return true
        case ("#crawlbar", "border-radius"):
            guard let radius = points(declaration.value) else { return false }
            settings.appearance.crawlCornerRadius = clamp(
                radius, AppSettings.AppearanceSettings.crawlCornerRadiusRange)
            return true
        case ("#page", "border-radius"):
            guard let radius = points(declaration.value) else { return false }
            settings.appearance.pageCornerRadius = clamp(
                radius, AppSettings.AppearanceSettings.pageCornerRadiusRange)
            return true
        default:
            return false
        }
    }

    private static func mapTabTheme(
        _ declaration: ThemeDeclaration,
        active: Bool,
        appearance: inout AppSettings.AppearanceSettings
    ) -> Bool {
        switch declaration.property {
        case "background-color":
            guard let color = backgroundColor(declaration.value) else { return false }
            if active {
                guard [BackgroundMediaConfiguration.Kind.none, BackgroundMediaConfiguration.Kind.solid]
                    .contains(appearance.activeTabTheme.background.kind)
                else { return false }
                appearance.activeTabTheme.background.kind = .solid
                appearance.activeTabTheme.background.solid.color = color
            } else {
                guard [BackgroundMediaConfiguration.Kind.none, BackgroundMediaConfiguration.Kind.solid]
                    .contains(appearance.tabTheme.background.kind)
                else { return false }
                appearance.tabTheme.background.kind = .solid
                appearance.tabTheme.background.solid.color = color
            }
            return true
        case "color":
            guard let color = backgroundColor(declaration.value) else { return false }
            if active {
                appearance.activeTabTheme.foreground = color
            } else {
                appearance.tabTheme.foreground = color
            }
            return true
        case "border-radius":
            guard let radius = points(declaration.value) else { return false }
            appearance.tabCornerRadius = clamp(
                radius, AppSettings.AppearanceSettings.tabCornerRadiusRange)
            return true
        case "opacity":
            guard let opacity = Double(declaration.value) else { return false }
            let clamped = min(max(opacity, 0), 1)
            if active {
                appearance.activeTabTheme.background.effects.opacity = clamped
            } else {
                appearance.tabTheme.background.effects.opacity = clamped
            }
            return true
        case "background-image":
            guard let gradient = ThemeStyleValue.gradient(
                ["background-image": declaration.value])
            else { return false }
            var built = BackgroundMediaConfiguration.Gradient()
            built.kind = .linear
            built.angle = gradient.angle
            built.stops = gradient.colors.enumerated().map { index, color in
                BackgroundMediaConfiguration.Gradient.Stop(
                    color: ThemeCSSSync.backgroundColor(color) ?? BackgroundColor(
                        red: 0, green: 0, blue: 0, alpha: 1),
                    location: gradient.colors.count == 1 ? 0 :
                        Double(index) / Double(gradient.colors.count - 1))
            }
            if active {
                guard [BackgroundMediaConfiguration.Kind.none, BackgroundMediaConfiguration.Kind.solid, BackgroundMediaConfiguration.Kind.gradient]
                    .contains(appearance.activeTabTheme.background.kind)
                else { return false }
                appearance.activeTabTheme.background.kind = .gradient
                appearance.activeTabTheme.background.gradient = built
            } else {
                guard [BackgroundMediaConfiguration.Kind.none, BackgroundMediaConfiguration.Kind.solid, BackgroundMediaConfiguration.Kind.gradient]
                    .contains(appearance.tabTheme.background.kind)
                else { return false }
                appearance.tabTheme.background.kind = .gradient
                appearance.tabTheme.background.gradient = built
            }
            return true
        default:
            return false
        }
    }

    /// `#rrggbb[aa]` to a stored color. Canonical values arrive well-formed
    /// from the core; anything else declines to map.
    static func backgroundColor(_ hex: String) -> BackgroundColor? {
        guard hex.hasPrefix("#") else { return nil }
        let digits = String(hex.dropFirst())
        guard digits.count == 6 || digits.count == 8,
              let value = UInt64(digits, radix: 16)
        else { return nil }
        if digits.count == 6 {
            return BackgroundColor(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                alpha: 1)
        }
        return BackgroundColor(
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            alpha: Double(value & 0xFF) / 255)
    }

    private static func backgroundColor(_ color: NSColor) -> BackgroundColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return BackgroundColor(
            red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }

    /// `Npx` to points.
    private static func points(_ text: String) -> Double? {
        guard text.hasSuffix("px") else { return nil }
        return Double(text.dropLast(2))
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
