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
        if background.isActive {
            look
            placement
            effects
        }
        if background.kind == .gradient { gradient }
        if background.kind == .image || background.kind == .video { videoOptions }
        transparency
    }

    // MARK: - Media

    private var media: some View {
        SettingsGroup(
            title: "Window Background",
            footnote: "Behind the page. Applies to every window as you change it."
        ) {
            SettingsPickerRow(
                title: "Fill With",
                options: BackgroundMediaConfiguration.Kind.allCases,
                selection: binding(\.appearance.background.kind),
                isSegmented: false,
                label: { $0.title }
            )

            if background.kind == .image || background.kind == .video {
                SettingsButtonRow(
                    title: mediaTitle,
                    subtitle: mediaSubtitle
                ) {
                    HStack(spacing: 6) {
                        Button("Choose…") { choose() }
                            .controlSize(.small)
                        if background.path != nil {
                            Button("Clear") {
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
                    subtitle: "The background has been turned off. Choose a different file."
                ) {
                    Button("Dismiss") { diagnostics.clear() }
                        .controlSize(.small)
                }
            }
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
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else {
            return "Missing or unreadable. Choose it again."
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(url.deletingLastPathComponent().path) · \(formatted)"
    }

    // MARK: - Look

    private var look: some View {
        SettingsGroup(title: "Size") {
            SettingsPickerRow(
                title: "Fit",
                options: BackgroundMediaConfiguration.Fit.allCases,
                selection: binding(\.appearance.background.fit),
                isSegmented: true,
                label: { $0.title }
            )
            if background.fit == .custom {
                SettingsSliderRow(
                    title: "Scale",
                    value: binding(\.appearance.background.fitScale),
                    range: 10...400,
                    step: 5,
                    format: { String(format: "%.0f%%", $0) }
                )
            }
            // AVPlayerLayer cannot tile, so offering it would be a control that
            // silently does nothing.
            if background.kind == .image {
                SettingsPickerRow(
                    title: "Repeat",
                    options: BackgroundMediaConfiguration.Repeat.allCases,
                    selection: binding(\.appearance.background.repeatMode),
                    isSegmented: true,
                    label: { $0.title }
                )
            }
        }
    }

    private var placement: some View {
        SettingsGroup(title: "Position") {
            SettingsPickerRow(
                title: "Anchor",
                options: BackgroundMediaConfiguration.Position.allCases,
                selection: binding(\.appearance.background.position),
                isSegmented: false,
                label: { $0.title }
            )
            if background.position == .custom {
                SettingsPickerRow(
                    title: "Horizontal",
                    options: BackgroundMediaConfiguration.Axis.Mode.allCases,
                    selection: binding(\.appearance.background.customX.mode),
                    isSegmented: true,
                    label: { $0.title }
                )
                if background.customX.mode == .percent || background.customX.mode == .point {
                    SettingsSliderRow(
                        title: "X",
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
                    title: "Vertical",
                    options: BackgroundMediaConfiguration.Axis.Mode.allCases,
                    selection: binding(\.appearance.background.customY.mode),
                    isSegmented: true,
                    label: { $0.title }
                )
                if background.customY.mode == .percent || background.customY.mode == .point {
                    SettingsSliderRow(
                        title: "Y",
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

    private var effects: some View {
        SettingsGroup(title: "Effects") {
            SettingsSliderRow(
                title: "Opacity",
                value: binding(\.appearance.background.effects.opacity),
                range: 0...1,
                step: 0.05,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            SettingsSliderRow(
                title: "Blur",
                value: binding(\.appearance.background.effects.blurRadius),
                range: 0...60,
                step: 1,
                format: { $0 <= 0.5 ? "None" : String(format: "%.0fpt", $0) }
            )
            SettingsSliderRow(
                title: "Brightness",
                value: binding(\.appearance.background.effects.brightness),
                range: 0.2...2,
                step: 0.05,
                format: { String(format: "%.2f×", $0) }
            )
            SettingsSliderRow(
                title: "Contrast",
                value: binding(\.appearance.background.effects.contrast),
                range: 0.2...2,
                step: 0.05,
                format: { String(format: "%.2f×", $0) }
            )
            SettingsSliderRow(
                title: "Saturation",
                value: binding(\.appearance.background.effects.saturation),
                range: 0...2,
                step: 0.05,
                format: { $0 <= 0.01 ? "None" : String(format: "%.2f×", $0) }
            )
            ColorRow(
                title: "Tint",
                color: binding(\.appearance.background.effects.overlay)
            )
        }
    }

    // MARK: - Gradient

    private var gradient: some View {
        SettingsGroup(
            title: "Gradient",
            footnote: "Stops are applied in order along the gradient."
        ) {
            SettingsPickerRow(
                title: "Kind",
                options: BackgroundMediaConfiguration.Gradient.Kind.allCases,
                selection: binding(\.appearance.background.gradient.kind),
                isSegmented: true,
                label: { $0.title }
            )
            if background.gradient.kind == .linear {
                SettingsSliderRow(
                    title: "Angle",
                    value: binding(\.appearance.background.gradient.angle),
                    range: 0...360,
                    step: 5,
                    format: { String(format: "%.0f°", $0) }
                )
            } else {
                SettingsSliderRow(
                    title: "Centre X",
                    value: binding(\.appearance.background.gradient.centerX),
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsSliderRow(
                    title: "Centre Y",
                    value: binding(\.appearance.background.gradient.centerY),
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsSliderRow(
                    title: "Inner Radius",
                    value: binding(\.appearance.background.gradient.startRadius),
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsSliderRow(
                    title: "Outer Radius",
                    value: binding(\.appearance.background.gradient.endRadius),
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
            }
            ForEach(store.settings.appearance.background.gradient.stops) { stop in
                GradientStopRow(stop: stopBinding(stop.id), onDelete: { removeStop(stop.id) })
            }
            SettingsButtonRow(
                title: "Add Stop",
                subtitle: background.gradient.stops.count >= 8 ? "Eight is the limit." : "A colour at a point along the gradient."
            ) {
                Button("Add") { addStop() }
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
            title: "Video",
            footnote: "Always silent and always looping: a window that starts making noise on its own is the problem this feature exists to solve, and a background that froze at the end would be nobody's idea of a background."
        ) {
            SettingsToggleRow(
                title: "Autoplay",
                subtitle: "Starts on its own when the window opens.",
                isOn: binding(\.appearance.background.video.autoplay)
            )
            SettingsToggleRow(
                title: "Respect Reduce Motion",
                subtitle: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? "The system currently asks for reduced motion, so this pauses the video."
                    : "The system is not asking for reduced motion.",
                isOn: binding(\.appearance.background.video.respectsReduceMotion)
            )
            SettingsToggleRow(
                title: "Pause When Inactive",
                subtitle: "Stops when another app is in front.",
                isOn: binding(\.appearance.background.video.pauseWhenInactive)
            )
            SettingsToggleRow(
                title: "Pause When Hidden",
                subtitle: "Stops when the window is covered, minimized or the app is hidden.",
                isOn: binding(\.appearance.background.video.pauseWhenHidden)
            )
            SettingsSliderRow(
                title: "Speed",
                value: binding(\.appearance.background.video.playbackSpeed),
                range: 0.25...4,
                step: 0.25,
                format: { String(format: "%.2f×", $0) }
            )
            SettingsSliderRow(
                title: "Start At",
                value: binding(\.appearance.background.video.startTime),
                range: 0...60,
                step: 1,
                format: { String(format: "%.0fs", $0) }
            )
        }
    }

    // MARK: - Transparency

    private var transparency: some View {
        SettingsGroup(
            title: "Show Through Pages",
            footnote: "Off by default. Forces pages to be see-through, which some sites lose their background over. Expect it to be partial: a site that paints its own background still covers the media."
        ) {
            SettingsToggleRow(
                title: "Transparent Pages",
                subtitle: background.isActive
                    ? "Lets the background show behind the page."
                    : "Needs a background first. Nothing to reveal yet.",
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
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = background.kind == .video ? [.movie] : [.image]
        panel.prompt = "Use"
        panel.message = background.kind == .video
            ? "Choose a video to play behind the page."
            : "Choose an image to show behind the page."

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            self.store.update { document in
                document.appearance.background.path = url.path
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.keyWindow else { return }
        // A sheet rather than a modal panel: it is ordered above the window's
        // content, which means the settings card's event shield cannot end up
        // over it, and it needs no extra coordination for that.
        panel.beginSheetModal(for: window) { response in apply(response) }
    }
}

/// One gradient stop: a colour and where it sits.
private struct GradientStopRow: View {
    @Binding var stop: BackgroundMediaConfiguration.Gradient.Stop
    let onDelete: () -> Void

    var body: some View {
        SettingsButtonRow(
            title: stop.color.hexString,
            subtitle: String(format: "%.0f%% along", stop.location * 100)
        ) {
            HStack(spacing: 6) {
                Slider(value: $stop.location, in: 0...1, step: 0.01)
                    .frame(width: 90)
                ColorPicker("", selection: colorBinding, supportsOpacity: true)
                    .labelsHidden()
                    .controlSize(.small)
                Button("Remove", action: onDelete)
                    .controlSize(.small)
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