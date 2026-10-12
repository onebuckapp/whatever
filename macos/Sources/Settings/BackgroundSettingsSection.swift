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

/// The background's settings rows.
///
/// Emits groups rather than a whole pane, because it lives inside Appearance
/// alongside the grain controls and a nested `SettingsDetailStack` would put a
/// scroll view inside a scroll view.
///
/// Every control writes straight through the store, so the window behind the
/// card changes as the control moves. Nothing here reloads a page or rebuilds the
/// layer, which is the point of the background being a sibling view rather than
/// anything owned by a tab.
struct BackgroundSettingsGroups: View {
    @ObservedObject private var store = SettingsStore.shared
    /// Reported by the layer rather than guessed at here, so the pane only says a
    /// file is unusable when something actually tried to read it.
    @ObservedObject private var diagnostics = BackgroundDiagnostics.shared

    private var background: BackgroundMediaConfiguration {
        store.settings.appearance.background
    }

    var body: some View {
        media
        kindSections
        transparency
        linkBubble
    }

    /// Only the sections the chosen renderer actually reads.
    ///
    /// Split out of `body` because a `switch` with a view-less case cannot sit in a
    /// `ViewBuilder` directly.
    @ViewBuilder
    private var kindSections: some View {
        switch background.kind {
        case .none:
            EmptyView()
        case .solid:
            solidFill
            effects
        case .gradient:
            gradient
            effects
        case .image:
            size
            position
            effects
        case .video:
            size
            effects
            videoOptions
        }
    }

    // MARK: - Media

    /// The floating link bubble's paint. Lives here rather than with the
    /// hover code because it is page chrome, like the corners above.
    private var linkBubble: some View {
        SettingsGroup(
            title: tr("Link Bubble", ctx: "Settings.Appearance"),
            footnote: tr("The floating address shown while hovering a link.", ctx: "Settings.Appearance")
        ) {
            SettingsSliderRow(
                title: tr("Opacity", ctx: "Settings.Appearance"),
                value: store.binding(\.appearance.linkHoverOpacity),
                range: AppSettings.AppearanceSettings.linkHoverOpacityRange,
                step: 0.05,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
        }
    }

    private var media: some View {
        SettingsGroup(
            title: tr("Window Background", ctx: "Settings.Appearance"),
            footnote: tr("Behind the page. Applies to every window as you change it.", ctx: "Settings.Appearance")
        ) {
            SettingsPickerRow(
                title: tr("Fill With", ctx: "Settings.Appearance"),
                options: BackgroundMediaConfiguration.Kind.allCases,
                selection: binding(\.appearance.background.kind),
                isSegmented: false,
                label: { $0.title }
            )

            if background.kind.showsMediaSize {
                SettingsButtonRow(
                    title: mediaTitle,
                    subtitle: mediaSubtitle
                ) {
                    HStack(spacing: 6) {
                        Button(tr("Choose…", ctx: "Settings.Appearance")) { choose() }
                            .controlSize(.small)
                        if background.path != nil {
                            Button(tr("Clear", ctx: "Settings.Appearance")) {
                                store.update { $0.appearance.background.path = nil }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            if let problem = diagnostics.lastError {
                SettingsButtonRow(
                    title: problem,
                    subtitle: tr("The background has been turned off. Choose a different file.", ctx: "Settings.Appearance")
                ) {
                    Button(tr("Dismiss", ctx: "Settings.Appearance")) { diagnostics.clear() }
                        .controlSize(.small)
                }
            }

            // The page's own bottom corners, which frame the background.
            SettingsSliderRow(
                title: tr("Page Corners", ctx: "Settings.Appearance"),
                value: store.binding(\.appearance.pageCornerRadius),
                range: AppSettings.AppearanceSettings.pageCornerRadiusRange,
                step: 0.5,
                format: { String(format: "%.1f pt", $0) }
            )
        }
    }

    private var mediaTitle: String {
        guard let path = background.path else { return tr("No file chosen", ctx: "Settings.Appearance") }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var mediaSubtitle: String {
        guard let path = background.path else {
            return background.kind == .video ? tr("A video file on disk.", ctx: "Settings.Appearance") : tr("An image file on disk.", ctx: "Settings.Appearance")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else {
            return tr("Missing or unreadable. Choose it again.", ctx: "Settings.Appearance")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(url.deletingLastPathComponent().path) · \(formatted)"
    }

    // MARK: - Solid

    private var solidFill: some View {
        SettingsGroup(title: tr("Colour", ctx: "Settings.Appearance")) {
            ColorRow(
                title: tr("Fill", ctx: "Settings.Appearance"),
                color: binding(\.appearance.background.solid.color)
            )
        }
    }

    // MARK: - Size

    /// Fit, and the scale that goes with it.
    ///
    /// The video renderer is offered only the two fits that reach `videoGravity`
    /// differently, and the getter reports the effective one so switching into
    /// video with an image's `stretch` or custom scale does not show a segmented
    /// control with nothing selected.
    private var size: some View {
        SettingsGroup(title: tr("Size", ctx: "Settings.Appearance")) {
            SettingsPickerRow(
                title: tr("Fit", ctx: "Settings.Appearance"),
                options: fitOptions,
                selection: fitSelection,
                isSegmented: true,
                label: { $0.title }
            )
            if background.fit == .custom && background.kind == .image {
                SettingsSliderRow(
                    title: tr("Scale", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.fitScale),
                    range: 10...400,
                    step: 5,
                    format: { String(format: "%.0f%%", $0) }
                )
            }
            if background.kind.showsRepeat {
                SettingsPickerRow(
                    title: tr("Repeat", ctx: "Settings.Appearance"),
                    options: BackgroundMediaConfiguration.Repeat.allCases,
                    selection: binding(\.appearance.background.repeatMode),
                    isSegmented: true,
                    label: { $0.title }
                )
            }
        }
    }

    private var fitOptions: [BackgroundMediaConfiguration.Fit] {
        background.kind == .video
            ? BackgroundMediaConfiguration.Fit.videoCases
            : BackgroundMediaConfiguration.Fit.allCases
    }

    private var fitSelection: Binding<BackgroundMediaConfiguration.Fit> {
        let keyPath = \AppSettings.appearance.background.fit
        guard background.kind == .video else { return store.binding(keyPath) }
        return Binding(
            get: { store.settings[keyPath: keyPath].effectiveVideoFit },
            set: { chosen in
                store.update { document in
                    document[keyPath: keyPath] = chosen
                }
            }
        )
    }

    private var position: some View {
        SettingsGroup(title: tr("Position", ctx: "Settings.Appearance")) {
            SettingsPickerRow(
                title: tr("Anchor", ctx: "Settings.Appearance"),
                options: BackgroundMediaConfiguration.Position.allCases,
                selection: binding(\.appearance.background.position),
                isSegmented: false,
                label: { $0.title }
            )
            if background.position == .custom {
                SettingsPickerRow(
                    title: tr("Horizontal", ctx: "Settings.Appearance"),
                    options: BackgroundMediaConfiguration.Axis.Mode.allCases,
                    selection: binding(\.appearance.background.customX.mode),
                    isSegmented: true,
                    label: { $0.title }
                )
                if background.customX.mode == .percent || background.customX.mode == .point {
                    SettingsSliderRow(
                        title: tr("X", ctx: "Settings.Appearance"),
                        value: binding(\.appearance.background.customX.value),
                        range: background.customX.mode == .percent ? 0...100 : -400...400,
                        step: 1,
                        format: {
                            background.customX.mode == .percent
                                ? String(format: "%.0f%%", $0)
                                : String(format: "%.0fpt", $0)
                        }
                    )
                }
                SettingsPickerRow(
                    title: tr("Vertical", ctx: "Settings.Appearance"),
                    options: BackgroundMediaConfiguration.Axis.Mode.allCases,
                    selection: binding(\.appearance.background.customY.mode),
                    isSegmented: true,
                    label: { $0.title }
                )
                if background.customY.mode == .percent || background.customY.mode == .point {
                    SettingsSliderRow(
                        title: tr("Y", ctx: "Settings.Appearance"),
                        value: binding(\.appearance.background.customY.value),
                        range: background.customY.mode == .percent ? 0...100 : -400...400,
                        step: 1,
                        format: {
                            background.customY.mode == .percent
                                ? String(format: "%.0f%%", $0)
                                : String(format: "%.0fpt", $0)
                        }
                    )
                }
            }
        }
    }

    /// Opacity and tint always; grading only where there is an image to grade.
    ///
    /// Opacity rides on the view and the tint is painted over whatever was drawn,
    /// so both work for every kind. The other four run inside
    /// `BackgroundImageStore` and never touch a colour, a gradient, or a video's
    /// own frames.
    private var effects: some View {
        SettingsGroup(title: tr("Effects", ctx: "Settings.Appearance")) {
            SettingsSliderRow(
                title: tr("Opacity", ctx: "Settings.Appearance"),
                value: binding(\.appearance.background.effects.opacity),
                range: 0...1,
                step: 0.05,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            ColorRow(
                title: tr("Tint", ctx: "Settings.Appearance"),
                color: binding(\.appearance.background.effects.overlay)
            )
            if background.kind.showsGrading(hasPoster: background.hasPoster) {
                SettingsSliderRow(
                    title: tr("Blur", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.effects.blurRadius),
                    range: 0...60,
                    step: 1,
                    format: { $0 <= 0.5 ? "None" : String(format: "%.0fpt", $0) }
                )
                SettingsSliderRow(
                    title: tr("Brightness", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.effects.brightness),
                    range: 0.2...2,
                    step: 0.05,
                    format: { String(format: "%.2f×", $0) }
                )
                SettingsSliderRow(
                    title: tr("Contrast", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.effects.contrast),
                    range: 0.2...2,
                    step: 0.05,
                    format: { String(format: "%.2f×", $0) }
                )
                SettingsSliderRow(
                    title: tr("Saturation", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.effects.saturation),
                    range: 0...2,
                    step: 0.05,
                    format: { $0 <= 0.01 ? "None" : String(format: "%.2f×", $0) }
                )
            }
        }
    }

    // MARK: - Gradient

    private var gradient: some View {
        SettingsGroup(
            title: tr("Gradient", ctx: "Settings.Appearance"),
            footnote: tr("Stops are applied in order along the gradient.", ctx: "Settings.Appearance")
        ) {
            SettingsPickerRow(
                title: tr("Kind", ctx: "Settings.Appearance"),
                options: BackgroundMediaConfiguration.Gradient.Kind.allCases,
                selection: binding(\.appearance.background.gradient.kind),
                isSegmented: true,
                label: { $0.title }
            )
            if background.gradient.kind == .linear {
                SettingsSliderRow(
                    title: tr("Angle", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.gradient.angle),
                    range: 0...360,
                    step: 5,
                    format: { String(format: "%.0f°", $0) }
                )
            } else {
                SettingsSliderRow(
                    title: tr("Centre X", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.gradient.centerX),
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsSliderRow(
                    title: tr("Centre Y", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.gradient.centerY),
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsSliderRow(
                    title: tr("Inner Radius", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.gradient.startRadius),
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsSliderRow(
                    title: tr("Outer Radius", ctx: "Settings.Appearance"),
                    value: binding(\.appearance.background.gradient.endRadius),
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
            }
            ForEach(store.settings.appearance.background.gradient.stops) { stop in
                GradientStopRow(
                    stop: stopBinding(stop.id),
                    canRemove: store.settings.appearance.background.gradient.stops.count > 2,
                    onDelete: { removeStop(stop.id) }
                )
            }
            SettingsButtonRow(
                title: tr("Add Stop", ctx: "Settings.Appearance"),
                subtitle: background.gradient.stops.count >= 8
                    ? tr("Eight is the limit.", ctx: "Settings.Appearance")
                    : tr("A colour at a point along the gradient.", ctx: "Settings.Appearance")
            ) {
                Button(tr("Add", ctx: "Settings.Appearance")) { addStop() }
                    .controlSize(.small)
                    .disabled(background.gradient.stops.count >= 8)
            }
        }
    }

    private func addStop() {
        store.update { document in
            let stops = document.appearance.background.gradient.stops
            // New stops go at the far end unless that is already taken, so the
            // new colour is visible immediately instead of hiding under an
            // existing stop.
            let location = (stops.map(\.location).max() ?? 0) < 0.99 ? 1 : 0.5
            let color = stops.last?.color
                ?? BackgroundColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            document.appearance.background.gradient.stops.append(
                BackgroundMediaConfiguration.Gradient.Stop(color: color, location: location)
            )
            document.appearance.background.gradient.stops.sort { $0.location < $1.location }
        }
    }

    private func removeStop(_ id: UUID) {
        store.update { document in
            document.appearance.background.gradient.stops.removeAll { $0.id == id }
        }
    }

    /// A two-way binding onto one gradient stop.
    ///
    /// Written field by field rather than through a `$store` binding because the
    /// store's settings are `private(set)`: every write has to go via `update`, or
    /// it would skip the store's change detection and its debounced save.
    private func stopBinding(_ id: UUID) -> Binding<BackgroundMediaConfiguration.Gradient.Stop> {
        Binding(
            get: {
                store.settings.appearance.background.gradient.stops.first { $0.id == id }
                    ?? BackgroundMediaConfiguration.Gradient.Stop(
                        color: .init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                        location: 0
                    )
            },
            set: { newValue in
                store.update { document in
                    guard let index = document.appearance.background.gradient.stops
                        .firstIndex(where: { $0.id == id })
                    else { return }
                    document.appearance.background.gradient.stops[index] = newValue
                }
            }
        )
    }

    // MARK: - Video

    private var videoOptions: some View {
        SettingsGroup(
            title: tr("Video", ctx: "Settings.Appearance"),
            footnote: tr("Always silent and always looping: a window that starts making noise on its own is the problem this feature exists to solve, and a background that froze at the end would be nobody's idea of a background.", ctx: "Settings.Appearance")
        ) {
            SettingsToggleRow(
                title: tr("Autoplay", ctx: "Settings.Appearance"),
                subtitle: tr("Starts on its own when the window opens.", ctx: "Settings.Appearance"),
                isOn: binding(\.appearance.background.video.autoplay)
            )
            SettingsToggleRow(
                title: tr("Respect Reduce Motion", ctx: "Settings.Appearance"),
                subtitle: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? tr("The system currently asks for reduced motion, so this pauses the video.", ctx: "Settings.Appearance")
                    : tr("The system is not asking for reduced motion.", ctx: "Settings.Appearance"),
                isOn: binding(\.appearance.background.video.respectsReduceMotion)
            )
            SettingsToggleRow(
                title: tr("Pause When Inactive", ctx: "Settings.Appearance"),
                subtitle: tr("Stops when another app is in front.", ctx: "Settings.Appearance"),
                isOn: binding(\.appearance.background.video.pauseWhenInactive)
            )
            SettingsToggleRow(
                title: tr("Pause When Hidden", ctx: "Settings.Appearance"),
                subtitle: tr("Stops when the window is covered, minimized or the app is hidden.", ctx: "Settings.Appearance"),
                isOn: binding(\.appearance.background.video.pauseWhenHidden)
            )
            SettingsSliderRow(
                title: tr("Speed", ctx: "Settings.Appearance"),
                value: binding(\.appearance.background.video.playbackSpeed),
                range: 0.25...4,
                step: 0.25,
                format: { String(format: "%.2f×", $0) }
            )
            SettingsSliderRow(
                title: tr("Start At", ctx: "Settings.Appearance"),
                value: binding(\.appearance.background.video.startTime),
                range: 0...60,
                step: 1,
                format: { String(format: "%.0fs", $0) }
            )
            SettingsButtonRow(
                title: posterTitle,
                subtitle: tr("Stands in until the first frame arrives. It is also the only thing the Effects grading applies to for a video.", ctx: "Settings.Appearance")
            ) {
                HStack(spacing: 6) {
                    Button(tr("Choose…", ctx: "Settings.Appearance")) { choose(.poster) }
                        .controlSize(.small)
                    if background.video.posterPath != nil {
                        Button(tr("Clear", ctx: "Settings.Appearance")) {
                            store.update { $0.appearance.background.video.posterPath = nil }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var posterTitle: String {
        guard let path = background.video.posterPath else { return tr("No poster chosen", ctx: "Settings.Appearance") }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Transparency

    private var transparency: some View {
        SettingsGroup(
            title: tr("Show Through Pages", ctx: "Settings.Appearance"),
            footnote: tr("Off by default. Forces pages to be see-through, which some sites lose their background over. Expect it to be partial: a site that paints its own background still covers the media.", ctx: "Settings.Appearance")
        ) {
            SettingsToggleRow(
                title: tr("Transparent Pages", ctx: "Settings.Appearance"),
                subtitle: background.isActive
                    ? tr("Lets the background show behind the page.", ctx: "Settings.Appearance")
                    : tr("Needs a background first. Nothing to reveal yet.", ctx: "Settings.Appearance"),
                isOn: binding(\.appearance.background.showThroughPages)
            )
            .disabled(!background.isActive)
        }
    }

    // MARK: - Helpers

    private func binding<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        store.binding(keyPath)
    }

    /// Presents the open panel from inside a SwiftUI card hosted in an
    /// `NSHostingView`. `NSApp.activate` first, because the sheet belongs to the
    /// window and a background app would otherwise open it behind itself.
    ///
    /// One panel for the media and the poster, differing only in what they accept
    /// and which path they write.
    private func choose(_ target: FileTarget = .media) {
        let isPoster = target == .poster
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = isPoster ? [.image] : (background.kind == .video ? [.movie] : [.image])
        panel.prompt = tr("Use", ctx: "Settings.Appearance")
        panel.message = isPoster
            ? tr("Choose a still to show until the first video frame arrives.", ctx: "Settings.Appearance")
            : (background.kind == .video
                ? tr("Choose a video to play behind the page.", ctx: "Settings.Appearance")
                : tr("Choose an image to show behind the page.", ctx: "Settings.Appearance"))

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            self.store.update { document in
                if isPoster {
                    document.appearance.background.video.posterPath = url.path
                } else {
                    document.appearance.background.path = url.path
                }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.keyWindow else { return }
        // A sheet rather than a modal panel: it is ordered above the window's
        // content, which means the settings card's event shield cannot end up
        // over it, and it needs no extra coordination for that.
        panel.beginSheetModal(for: window) { response in apply(response) }
    }

    /// Which of the two file-backed fields the panel is writing to.
    private enum FileTarget {
        case media
        case poster
    }
}

/// One gradient stop: a colour and where it sits. Shared with the tab theme
/// rows, which edit the same gradient model on their own themes.
struct GradientStopRow: View {
    @Binding var stop: BackgroundMediaConfiguration.Gradient.Stop
    /// A gradient needs two stops to exist at all, and `isUsable` says so, so
    /// below two the background quietly stops drawing with nothing on screen
    /// saying why. Deleting is floored rather than allowed to blank the window.
    var canRemove: Bool
    let onDelete: () -> Void

    var body: some View {
        SettingsButtonRow(
            title: stop.color.hexString,
            subtitle: tr("{percent}% along", ctx: "Settings.Appearance", args: ["percent": String(format: "%.0f", stop.location * 100)])
        ) {
            HStack(spacing: 6) {
                Slider(value: $stop.location, in: 0...1, step: 0.01)
                    .frame(width: 90)
                ColorPicker("", selection: colorBinding, supportsOpacity: true)
                    .labelsHidden()
                    .controlSize(.small)
                Button(tr("Remove", ctx: "Settings.Appearance"), action: onDelete)
                    .controlSize(.small)
                    .disabled(!canRemove)
            }
        }
    }

    /// `ColorPicker` wants a `Binding<Color>`, and `Color` is not `Equatable`
    /// across a round trip, so the binding converts rather than storing it.
    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: stop.color.red,
                    green: stop.color.green,
                    blue: stop.color.blue,
                    opacity: stop.color.alpha
                )
            },
            set: { newValue in
                if let resolved = NSColor(newValue).usingColorSpace(.sRGB) {
                    stop.color = BackgroundColor(resolved)
                }
            }
        )
    }
}

/// A colour and an opacity slider, for the flat tint laid over the media.
private struct ColorRow: View {
    let title: String
    @Binding var color: BackgroundColor

    var body: some View {
        SettingsButtonRow(title: title, subtitle: color.alpha <= 0.001 ? "None" : color.hexString) {
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

extension BackgroundColor {
    /// Same colour, different alpha.
    func withAlpha(_ alpha: Double) -> BackgroundColor {
        BackgroundColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}