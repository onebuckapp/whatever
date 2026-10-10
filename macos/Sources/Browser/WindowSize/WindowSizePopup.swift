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
import MijickPopups
import SwiftUI

/// Parses and clamps the window-size form's fields. Pure values, no window
/// needed, so the rules are unit-testable without showing a card.
enum WindowSizeForm {
    static let minimumWidth: CGFloat = 400
    static let minimumHeight: CGFloat = 300
    static let maximumDimension: CGFloat = 4000

    /// Both fields must be finite positive numbers; anything else is a
    /// failed parse, and the card says so instead of resizing.
    static func parse(width: String, height: String) -> NSSize? {
        guard let w = dimension(width), let h = dimension(height) else {
            return nil
        }
        return NSSize(width: w, height: h)
    }

    /// Keeps a size inside the usable range: too small would collapse the
    /// chrome, too large would throw the window off every screen.
    static func clamped(_ size: NSSize) -> NSSize {
        NSSize(
            width: min(max(size.width, minimumWidth), maximumDimension),
            height: min(max(size.height, minimumHeight), maximumDimension)
        )
    }

    private static func dimension(_ text: String) -> CGFloat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = Double(trimmed),
              value.isFinite, value > 0
        else {
            return nil
        }
        return CGFloat(value)
    }
}

/// Small centered card that resizes the window's content area, presented by
/// Mijick/Popups like the grain card. Window-level, so the host fills the
/// whole content view rather than one page pane.
struct WindowSizePopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    let initialWidth: CGFloat
    let initialHeight: CGFloat

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.clear)
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            WindowSizePopupCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        WindowSizeCard(
            initialWidth: initialWidth,
            initialHeight: initialHeight,
            onApply: { size in
                WindowSizePopupCoordinator.shared.apply(id: popupID, size: size)
            },
            onCancel: {
                Task {
                    await PopupStack.dismissPopup(popupID, popupStackID: stackID)
                }
            }
        )
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

/// The width/height form itself, shown inside the card above (or any other
/// host, previews and tests included).
struct WindowSizeCard: View {
    /// Tab order through the form, buttons included: without explicit focus
    /// bindings SwiftUI leaves Tab dead inside the hosted card.
    private enum Field: Hashable {
        case width, height, apply
    }

    @State private var widthText: String
    @State private var heightText: String
    @State private var failure: String?
    @FocusState private var focusedField: Field?
    @State private var tabMonitor: Any?

    var onApply: ((NSSize) -> Void)?
    var onCancel: (() -> Void)?

    init(
        initialWidth: CGFloat,
        initialHeight: CGFloat,
        onApply: ((NSSize) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        _widthText = State(initialValue: String(Int(initialWidth.rounded())))
        _heightText = State(initialValue: String(Int(initialHeight.rounded())))
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Window Size")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            VStack(spacing: 10) {
                fieldRow("Width", text: $widthText, field: .width)
                fieldRow("Height", text: $heightText, field: .height)
                if let failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            HStack {
                Button("Cancel") {
                    onCancel?()
                }
                .controlSize(.small)
                Spacer()
                Button("Apply") {
                    apply()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .focused($focusedField, equals: .apply)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        // The caret starts in the width field: typed-first, no click
        // needed. Delayed because the card presents asynchronously and a
        // focus set before the window has taken key is silently dropped.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            focusedField = .width
            try? await Task.sleep(for: .milliseconds(200))
            if focusedField == nil {
                focusedField = .width
            }
        }
        .onAppear {
            // Tab and Shift+Tab cycle the form explicitly. The fields'
            // AppKit editor eats Tab before SwiftUI's focus engine sees it,
            // so bindings alone leave Tab dead: this monitor runs first
            // and swallows only Tabs pressed while this form holds focus,
            // so Tab anywhere else in the window is untouched.
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
                        ? nextField(after: focus.wrappedValue)
                        : previousField(before: focus.wrappedValue)
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

    private func fieldRow(
        _ title: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 52, alignment: .leading)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focusedField, equals: field)
                .onSubmit { apply() }
            Text("px")
                .foregroundStyle(.secondary)
        }
    }

    private func apply() {
        guard let size = WindowSizeForm.parse(width: widthText, height: heightText) else {
            failure = "Enter positive numbers for both width and height."
            SystemBeep.play()
            return
        }
        failure = nil
        onApply?(WindowSizeForm.clamped(size))
    }

    private func nextField(after field: Field?) -> Field? {
        switch field {
        case .width: .height
        case .height: .apply
        case .apply: .width
        case nil: .width
        }
    }

    private func previousField(before field: Field?) -> Field? {
        switch field {
        case .width: .apply
        case .height: .width
        case .apply: .height
        case nil: .width
        }
    }
}

/// Root view hosted inside a window's content view: registers the popup
/// stack, then presents the card once the stack is on screen.
struct WindowSizeRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let initialWidth: CGFloat
    let initialHeight: CGFloat

    var body: some View {
        Color.clear
            .registerPopups(id: stackID) { config in
                config.center { popup in
                    popup
                        .backgroundColor(.clear)
                        .cornerRadius(20)
                        .overlayColor(.clear)
                        .tapOutsideToDismissPopup(true)
                }
            }
            .task {
                await WindowSizePopup(
                    stackID: stackID,
                    popupID: popupID,
                    initialWidth: initialWidth,
                    initialHeight: initialHeight
                )
                .present(popupStackID: stackID)
            }
    }
}

/// Bridges one window to Mijick/Popups for the size card.
///
/// The hosting view fills the window content, so the card centers over the
/// whole window and tap-outside covers the page. Dismissal is owned here
/// for Escape and window teardown; Mijick-driven dismissal reports back
/// through the coordinator.
@MainActor
final class WindowSizePresenter {
    private weak var container: NSView?
    private var hostingView: NSHostingView<WindowSizeRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?
    private var onApply: ((NSSize) -> Void)?
    private var onDidDismiss: (() -> Void)?

    init(
        container: NSView,
        onApply: ((NSSize) -> Void)? = nil,
        onDidDismiss: (() -> Void)? = nil
    ) {
        self.container = container
        self.onApply = onApply
        self.onDidDismiss = onDidDismiss
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    func present(initial: NSSize) {
        guard let container else { return }
        resetForReuse()

        let stackID = PopupStackID(rawValue: "window-size-\(UUID().uuidString)")
        let popupID = "window-size"
        let root = WindowSizeRootView(
            stackID: stackID,
            popupID: popupID,
            initialWidth: initial.width,
            initialHeight: initial.height
        )
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
        WindowSizePopupCoordinator.shared.registerApply(id: popupID) { [weak self] size in
            self?.apply(size: size)
        }
        WindowSizePopupCoordinator.shared.registerDismiss(id: popupID) { [weak self] in
            self?.tearDown()
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

    /// Resizes through the owner, then closes: the card's job is done and
    /// leaving it open over a resized window serves nothing.
    private func apply(size: NSSize) {
        onApply?(size)
        dismiss()
    }

    /// Single teardown path, whether dismissal came from the host (Apply,
    /// Cancel, Escape), from Mijick's tap-outside layer, or from the shield
    /// swallowing a click.
    private func tearDown() {
        resetForReuse()
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

/// Routes Mijick's popup lifecycle callbacks and the card's Apply back to
/// the presenter that owns the hosting view. Popup structs must stay
/// `Sendable`, so they cannot hold the presenter directly.
@MainActor
final class WindowSizePopupCoordinator {
    static let shared = WindowSizePopupCoordinator()

    private var applyHandlers: [String: (NSSize) -> Void] = [:]
    private var dismissHandlers: [String: () -> Void] = [:]

    func registerApply(id: String, handler: @escaping (NSSize) -> Void) {
        applyHandlers[id] = handler
    }

    func registerDismiss(id: String, handler: @escaping () -> Void) {
        dismissHandlers[id] = handler
    }

    func apply(id: String, size: NSSize) {
        applyHandlers[id]?(size)
    }

    func popupDidDismiss(id: String) {
        applyHandlers.removeValue(forKey: id)
        dismissHandlers.removeValue(forKey: id)?()
    }
}
