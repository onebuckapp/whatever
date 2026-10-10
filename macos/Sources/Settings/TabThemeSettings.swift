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
/// background (none, solid, gradient, image, or video) and its own
/// foreground colour.
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
            title: "Tab Shape",
            footnote: "Attached tabs join the page; pills float with a gap above it and are always fully rounded, ignoring Corner Radius below."
        ) {
            SettingsPickerRow(
                title: "Shape",
                options: TabShape.allCases,
                selection: store.binding(\.appearance.tabShape),
                isSegmented: true,
                label: { $0.title }
            )
        }
        SettingsGroup(
            title: "Tab Corners",
            footnote: "Roundness of every attached tab cell. Follows live as it changes."
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
/// The kind picker offers none, solid, gradient, image, and video — everything
/// the window background offers, minus nothing: the cell already renders a
/// gradient from a hand-edited document, so these rows just expose it.
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
                    .gradient,
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
                gradientEditor
            case .image:
                mediaButtons
                SettingsPickerRow(
                    title: "Fit",
                    options: [
                        BackgroundMediaConfiguration.Fit.fill,
                        .contain,
                        .custom,
                    ],
                    selection: $theme.background.fit,
                    isSegmented: true,
                    label: { $0.title }
                )
                if theme.background.fit == .custom {
                    SettingsSliderRow(
                        title: "Scale",
                        value: $theme.background.fitScale,
                        range: 10...400,
                        step: 5,
                        format: { String(format: "%.0f%%", $0) }
                    )
                }
                SettingsPickerRow(
                    title: "Position",
                    options: TabImageVerticalAnchor.allCases,
                    selection: anchorBinding,
                    isSegmented: true,
                    label: { $0.title }
                )
            case .video:
                mediaButtons
            }

            // Tint and opacity over the picture: the tint lays a flat colour
            // across image and video alike, and opacity fades the themed
            // background without touching the text or the selection wash.
            // Offered only where there is a picture to combine with — over
            // nothing or a flat fill these rows would do nothing visible.
            if background.kind == .image || background.kind == .video {
                SettingsSliderRow(
                    title: "Opacity",
                    value: $theme.background.effects.opacity,
                    range: 0...1,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                TabThemeColorRow(
                    title: "Tint",
                    color: $theme.background.effects.overlay
                )
            }

            TabThemeForegroundRow(foreground: $theme.foreground)
        }
    }

    /// Linear or radial gradient controls for this tab state, mirroring the
    /// window background's gradient section on a smaller footprint: the tab
    /// cell renders the same gradient model, so the rows edit it in place.
    /// Writes go through the theme binding, which the store binding carries
    /// back with change detection and the debounced save.
    @ViewBuilder
    private var gradientEditor: some View {
        SettingsPickerRow(
            title: "Kind",
            options: BackgroundMediaConfiguration.Gradient.Kind.allCases,
            selection: $theme.background.gradient.kind,
            isSegmented: true,
            label: { $0.title }
        )
        if theme.background.gradient.kind == .linear {
            SettingsSliderRow(
                title: "Angle",
                value: $theme.background.gradient.angle,
                range: 0...360,
                step: 5,
                format: { String(format: "%.0f°", $0) }
            )
        } else {
            SettingsSliderRow(
                title: "Centre X",
                value: $theme.background.gradient.centerX,
                range: 0...1,
                step: 0.01,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            SettingsSliderRow(
                title: "Centre Y",
                value: $theme.background.gradient.centerY,
                range: 0...1,
                step: 0.01,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            SettingsSliderRow(
                title: "Inner Radius",
                value: $theme.background.gradient.startRadius,
                range: 0...1,
                step: 0.01,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            SettingsSliderRow(
                title: "Outer Radius",
                value: $theme.background.gradient.endRadius,
                range: 0...1,
                step: 0.01,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
        }
        ForEach(theme.background.gradient.stops) { stop in
            GradientStopRow(
                stop: stopBinding(stop.id),
                canRemove: theme.background.gradient.stops.count > 2,
                onDelete: { removeStop(stop.id) }
            )
        }
        SettingsButtonRow(
            title: "Add Stop",
            subtitle: theme.background.gradient.stops.count >= 8
                ? "Eight is the limit."
                : "A colour at a point along the gradient."
        ) {
            Button("Add") { addStop() }
                .controlSize(.small)
                .disabled(theme.background.gradient.stops.count >= 8)
        }
    }

    private func addStop() {
        let stops = theme.background.gradient.stops
        // New stops go at the far end unless that is already taken, so the
        // new colour is visible immediately instead of hiding under an
        // existing stop.
        let location = (stops.map(\.location).max() ?? 0) < 0.99 ? 1 : 0.5
        let color = stops.last?.color
            ?? BackgroundColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        theme.background.gradient.stops.append(
            BackgroundMediaConfiguration.Gradient.Stop(color: color, location: location)
        )
        theme.background.gradient.stops.sort { $0.location < $1.location }
    }

    private func removeStop(_ id: UUID) {
        theme.background.gradient.stops.removeAll { $0.id == id }
    }

    /// A two-way binding onto one gradient stop, falling back to a throwaway
    /// when the stop is gone: the row unmounts on the next render either way.
    private func stopBinding(_ id: UUID) -> Binding<BackgroundMediaConfiguration.Gradient.Stop> {
        Binding(
            get: {
                theme.background.gradient.stops.first { $0.id == id }
                    ?? BackgroundMediaConfiguration.Gradient.Stop(
                        color: .init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                        location: 0
                    )
            },
            set: { newValue in
                guard let index = theme.background.gradient.stops
                    .firstIndex(where: { $0.id == id })
                else { return }
                theme.background.gradient.stops[index] = newValue
            }
        )
    }

    /// The file picker row shared by images and videos.
    private var mediaButtons: some View {
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

    /// The image's vertical anchor as a three-way choice. Stored in the
    /// shared nine-way position (middle column); anything else in there —
    /// a hand-edited document, the corners — reads as its nearest row.
    private var anchorBinding: Binding<TabImageVerticalAnchor> {
        Binding(
            get: { TabImageVerticalAnchor.from(theme.background.position) },
            set: { theme.background.position = $0.position }
        )
    }

    private var mediaTitle: String {        guard let path = background.path else { return "No file chosen" }
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

/// Where a tab image sits vertically: which edge the picture holds while
/// the cell crops or letterboxes around it. A 32pt strip has no room for
/// the window background's nine-way grid, so rows offer the middle column.
/// Shared with tests, which pin the mapping to the shared position.
enum TabImageVerticalAnchor: String, CaseIterable, Identifiable {
    case top, center, bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top"
        case .center: return "Center"
        case .bottom: return "Bottom"
        }
    }

    var position: BackgroundMediaConfiguration.Position {
        switch self {
        case .top: return .topCenter
        case .center: return .center
        case .bottom: return .bottomCenter
        }
    }

    static func from(_ position: BackgroundMediaConfiguration.Position) -> Self {
        switch position {
        case .topLeft, .topCenter, .topRight:
            return .top
        case .bottomLeft, .bottomCenter, .bottomRight:
            return .bottom
        case .centerLeft, .center, .centerRight, .custom:
            return .center
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
