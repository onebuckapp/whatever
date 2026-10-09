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
import UniformTypeIdentifiers

/// Tab chrome theming rows: one group per tab state, each with its own
/// background (none, solid, image, or video — the tab subset of the window
/// background kinds) and its own foreground colour.
///
/// Every control writes straight through the store, so the tab strip behind
/// the card re-themes as the control moves. Emits groups rather than a whole
/// pane, because it lives inside Appearance alongside the other groups.
struct TabThemeSettingsGroups: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        TabThemeGroup(
            title: "Inactive Tabs",
            footnote: "Background and text for every tab but the selected one.",
            theme: store.binding(\.appearance.tabTheme)
        )
        TabThemeGroup(
            title: "Current Tab",
            footnote: "Background and text for the selected tab.",
            theme: store.binding(\.appearance.activeTabTheme)
        )
        SettingsGroup(
            title: "Tab Corners",
            footnote: "Roundness of every tab cell, active and inactive alike. Follows live as it changes."
        ) {
            SettingsSliderRow(
                title: "Corner Radius",
                value: store.binding(\.appearance.tabCornerRadius),
                range: AppSettings.AppearanceSettings.tabCornerRadiusRange,
                step: 0.5,
                format: { String(format: "%.1f pt", $0) }
            )
        }
    }
}

/// One tab state's background plus foreground.
///
/// The kind picker offers the tab subset (none, solid, image, video): the
/// model can also hold a gradient, which the cell renders but these rows do
/// not offer, matching the window background's rule that a row which does
/// nothing is worse than an absent one.
private struct TabThemeGroup: View {
    let title: String
    let footnote: String
    @Binding var theme: TabThemeConfiguration

    private var background: BackgroundMediaConfiguration {
        theme.background
    }

    var body: some View {
        SettingsGroup(title: title, footnote: footnote) {
            SettingsPickerRow(
                title: "Fill With",
                options: [
                    BackgroundMediaConfiguration.Kind.none,
                    .solid,
                    .image,
                    .video,
                ],
                selection: $theme.background.kind,
                isSegmented: false,
                label: { $0.title }
            )

            switch background.kind {
            case .none:
                EmptyView()
            case .solid:
                TabThemeColorRow(
                    title: "Fill",
                    color: $theme.background.solid.color
                )
            case .gradient:
                // Reachable only from a hand-edited document: the cell
                // renders it, and these rows leave it alone rather than
                // offering controls that would silently replace it.
                EmptyView()
            case .image, .video:
                SettingsButtonRow(
                    title: mediaTitle,
                    subtitle: mediaSubtitle
                ) {
                    HStack(spacing: 6) {
                        Button("Choose…") { choose() }
                            .controlSize(.small)
                        if background.path != nil {
                            Button("Clear") {
                                theme.background.path = nil
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            TabThemeForegroundRow(foreground: $theme.foreground)
        }
    }

    private var mediaTitle: String {
        guard let path = background.path else { return "No file chosen" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var mediaSubtitle: String {
        guard let path = background.path else {
            return background.kind == .video ? "A video file on disk." : "An image file on disk."
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return "Missing or unreadable. Choose it again."
        }
        let url = URL(fileURLWithPath: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(url.deletingLastPathComponent().path) · \(formatted)"
    }

    /// Presents the open panel from inside a SwiftUI card hosted in an
    /// `NSHostingView`. `NSApp.activate` first, because the sheet belongs to
    /// the window and a background app would otherwise open it behind itself.
    private func choose() {
        let isVideo = background.kind == .video
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = isVideo ? [.movie] : [.image]
        panel.prompt = "Use"
        panel.message = isVideo
            ? "Choose a video to play behind the tab."
            : "Choose an image to show behind the tab."

        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.keyWindow else { return }
        // A sheet rather than a modal panel: it is ordered above the window's
        // content, which means the settings card's event shield cannot end up
        // over it, and it needs no extra coordination for that.
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            theme.background.path = url.path
        }
    }
}

/// A colour well with opacity, mirroring the background pane's colour row.
///
/// `BackgroundColor` round-trips through sRGB components, so the stored
/// colour is the picked one rather than whatever the current appearance
/// calls it — the same reason the window background stores colours this way.
private struct TabThemeColorRow: View {
    let title: String
    @Binding var color: BackgroundColor

    var body: some View {
        SettingsButtonRow(
            title: title,
            subtitle: color.alpha <= 0.001 ? "None" : color.hexString
        ) {
            HStack(spacing: 6) {
                Slider(value: opacityBinding, in: 0...1, step: 0.05)
                    .frame(width: 80)
                ColorPicker("", selection: binding, supportsOpacity: true)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { color.alpha }, set: { color.alpha = $0 })
    }

    private var binding: Binding<Color> {
        Binding(
            get: { Color(red: color.red, green: color.green, blue: color.blue, opacity: 1) },
            set: { newValue in
                if let resolved = NSColor(newValue).usingColorSpace(.sRGB) {
                    color = BackgroundColor(resolved).withAlpha(color.alpha)
                }
            }
        )
    }
}

/// The tab's text and glyph colour, or the system look when unset.
///
/// A nil foreground is a real state, not an empty colour: it means exactly
/// the chrome from before themes existed, so clearing back to it must stay
/// one click away rather than requiring the user to eyeball-match grey.
private struct TabThemeForegroundRow: View {
    @Binding var foreground: BackgroundColor?

    var body: some View {
        SettingsButtonRow(
            title: "Text Colour",
            subtitle: foreground?.hexString ?? "System"
        ) {
            HStack(spacing: 6) {
                if foreground != nil {
                    Button("System") {
                        foreground = nil
                    }
                    .controlSize(.small)
                }
                ColorPicker("", selection: binding, supportsOpacity: true)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    private var binding: Binding<Color> {
        Binding(
            get: {
                if let foreground {
                    Color(red: foreground.red, green: foreground.green, blue: foreground.blue, opacity: 1)
                } else {
                    Color.primary
                }
            },
            set: { newValue in
                if let resolved = NSColor(newValue).usingColorSpace(.sRGB) {
                    let alpha = foreground?.alpha ?? 1
                    foreground = BackgroundColor(resolved).withAlpha(alpha)
                }
            }
        )
    }
}
