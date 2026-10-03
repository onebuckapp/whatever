import AppKit
import MijickPopups
import SwiftUI

/// Card with live controls for the grain overlay, presented by
/// Mijick/Popups like the QR card.
///
/// It edits `NoiseOverlaySettings.shared`, so every window's overlay
/// updates as a control moves and the values persist across launches.
struct NoiseOverlaySettingsPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            // Same dimmed backdrop as the QR card, so both popups read
            // as one presentation style.
            .overlayColor(.black.opacity(0.38))
            .tapOutsideToDismissPopup(true)
    }

    func onFocus() {
        Task { @MainActor in
            NoiseOverlayPopupCoordinator.shared.popupDidFocus(id: popupID)
        }
    }

    func onDismiss() {
        Task { @MainActor in
            NoiseOverlayPopupCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        NoiseOverlaySettingsCard {
            Task {
                await PopupStack.dismissPopup(popupID, popupStackID: stackID)
            }
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
        // Mijick masks the popup to its measured bounds, so the shadows
        // need transparent room; the padding is symmetric, so the card
        // stays centered.
        .padding(.vertical, 88)
        // Consume taps on the card itself. Without this a click on empty
        // card space reaches Mijick's full-window tap-outside layer and
        // closes the popup.
        .onTapGesture {}
        .onExitCommand {
            Task {
                await PopupStack.dismissPopup(popupID, popupStackID: stackID)
            }
        }
    }
}

/// The controls themselves, shown either inside the popup card or in
/// any other host (previews, tests).
struct NoiseOverlaySettingsCard: View {
    @ObservedObject private var settings = NoiseOverlaySettings.shared

    /// Called when the card is confirmed, so the host can dismiss it.
    var onSave: (() -> Void)?

    private var configuration: NoiseOverlayConfiguration {
        settings.configuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            footer
        }
        // The card's own shape, background, and shadow belong to
        // `NoiseOverlaySettingsPopup`, which applies the same treatment
        // as the QR card. Deliberately no `.noiseOverlay` here: the
        // window installs a single overlay above all its content, grain
        // included, so a second layer would double the grain.
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Toggle("Grain", isOn: settings.enabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer()
            Button {
                settings.rerollSeed()
            } label: {
                Image(systemName: "dice")
            }
            .help("Generate a different grain")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Color", selection: settings.colorModeBinding) {
                ForEach(GrainColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!configuration.isEnabled)

            slider("Opacity", value: settings.opacityBinding, range: 0...0.5)
            slider("Intensity", value: settings.intensityBinding, range: 0...1)
            slider("Contrast", value: settings.contrastBinding, range: 1...8)
            slider("Grain Size", value: settings.grainScaleBinding, range: 1...4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button("Reset") {
                settings.reset()
            }
            .controlSize(.small)
            Spacer()
            Button("Save") {
                // Values apply live; persisting is already done on every
                // change, so this only ends the editing session.
                onSave?()
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Rows

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
                .disabled(!configuration.isEnabled)
        }
    }

}

// MARK: - Shared grain bindings

/// Grain control bindings, shared by the standalone grain card and the Appearance
/// pane in settings.
///
/// They live on the settings object rather than in either view that renders them.
/// The card and the settings pane show the same controls, and every write has to go
/// through `update` so it is sanitized and persisted; a second copy of that in each
/// view is a third thing to keep in step when a grain field is added.
extension NoiseOverlaySettings {
    // MARK: - Bindings

    var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.configuration.isEnabled },
            set: { value in self.update { $0.isEnabled = value } }
        )
    }

    var colorModeBinding: Binding<GrainColorMode> {
        Binding(
            get: { self.configuration.colorMode },
            set: { value in self.update { $0.colorMode = value } }
        )
    }

    var opacityBinding: Binding<Double> {
        Binding(
            get: { Double(self.configuration.opacity) },
            set: { value in self.update { $0.opacity = CGFloat(value) } }
        )
    }

    var intensityBinding: Binding<Double> {
        Binding(
            get: { Double(self.configuration.intensity) },
            set: { value in self.update { $0.intensity = CGFloat(value) } }
        )
    }

    var contrastBinding: Binding<Double> {
        Binding(
            get: { Double(self.configuration.contrast) },
            set: { value in self.update { $0.contrast = CGFloat(value) } }
        )
    }

    var grainScaleBinding: Binding<Double> {
        Binding(
            get: { Double(self.configuration.grainScale) },
            set: { value in self.update { $0.grainScale = CGFloat(value) } }
        )
    }
}


/// Root view hosted inside a window's content view: registers the popup
/// stack, then presents the card once the stack is on screen.
struct NoiseOverlaySettingsRootView: View {
    let stackID: PopupStackID
    let popupID: String

    var body: some View {
        Color.clear
            .registerPopups(id: stackID) { config in
                config.center { popup in
                    popup
                        .backgroundColor(.clear)
                        .cornerRadius(20)
                        .overlayColor(.black.opacity(0.38))
                        .tapOutsideToDismissPopup(true)
                }
            }
            .task {
                await NoiseOverlaySettingsPopup(stackID: stackID, popupID: popupID)
                    .present(popupStackID: stackID)
            }
    }
}

/// Bridges one window to Mijick/Popups for the settings card.
///
/// The hosting view fills the window content, so the card centers over
/// the whole window and tap-outside covers the page. Dismissal is owned
/// here for Escape and window teardown; Mijick-driven dismissal reports
/// back through the coordinator.
@MainActor
final class NoiseOverlaySettingsPresenter {
    private weak var container: NSView?
    private var hostingView: NSHostingView<NoiseOverlaySettingsRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?
    private var onDidDismiss: (() -> Void)?

    init(container: NSView, onDidDismiss: (() -> Void)? = nil) {
        self.container = container
        self.onDidDismiss = onDidDismiss
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    /// `true` once Mijick reports the card as the top popup. The host
    /// view exists slightly earlier, so this is what distinguishes
    /// "requested" from "actually on screen".
    private(set) var isCardOnScreen = false

    func present() {
        guard let container else { return }
        resetForReuse()

        let stackID = PopupStackID(rawValue: "noise-settings-\(UUID().uuidString)")
        let popupID = "noise-settings"
        let root = NoiseOverlaySettingsRootView(stackID: stackID, popupID: popupID)
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.hostingView = hostingView
        self.stackID = stackID
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
                return nil
            }
            return event
        }
        NoiseOverlayPopupCoordinator.shared.register(id: popupID) { [weak self] in
            self?.tearDown()
        }
        NoiseOverlayPopupCoordinator.shared.registerFocus(id: popupID) { [weak self] in
            self?.isCardOnScreen = true
        }
    }

    func dismiss() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        tearDown()
    }

    /// Single teardown path, whether dismissal came from the host
    /// (Escape, Save, toolbar button), from Mijick's tap-outside layer,
    /// or from the shield swallowing a click.
    private func tearDown() {
        resetForReuse()
        isCardOnScreen = false
        let notify = onDidDismiss
        onDidDismiss = nil
        notify?()
    }

    /// Drops the host without touching shared state. Used when this same
    /// presenter is about to show a new popup.
    private func resetForReuse() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        hostingView?.removeFromSuperview()
        hostingView = nil
        stackID = nil
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }
}

/// Routes Mijick's popup lifecycle callbacks back to the presenter that
/// owns the hosting view. Popup structs must stay `Sendable`, so they
/// cannot hold the presenter directly.
@MainActor
final class NoiseOverlayPopupCoordinator {
    static let shared = NoiseOverlayPopupCoordinator()

    private var dismissHandlers: [String: () -> Void] = [:]
    private var focusHandlers: [String: () -> Void] = [:]

    func register(id: String, handler: @escaping () -> Void) {
        dismissHandlers[id] = handler
    }

    func registerFocus(id: String, handler: @escaping () -> Void) {
        focusHandlers[id] = handler
    }

    func popupDidFocus(id: String) {
        focusHandlers[id]?()
    }

    func popupDidDismiss(id: String) {
        focusHandlers.removeValue(forKey: id)
        dismissHandlers.removeValue(forKey: id)?()
    }
}