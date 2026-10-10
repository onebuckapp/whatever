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
import AVFoundation
import MijickPopups
import SwiftUI

/// What the capture popup shows for one site: pending requests, live
/// grants, and whether macOS itself is blocking the devices. A snapshot,
/// because popup structs must stay `Sendable` and cannot hold the tab:
/// verdicts flow back through the coordinator, and the card mirrors them
/// in local state.
struct MediaCaptureSnapshot: Equatable, Sendable {
    var host: String
    var isPrivate: Bool
    var pending: Set<AppSettings.MediaCaptureKind>
    var granted: Set<AppSettings.MediaCaptureKind>
    /// Origin hosts behind the pending requests, by kind: usually the page
    /// itself, an embedded frame's host when it asked.
    var requestHosts: [AppSettings.MediaCaptureKind: String] = [:]
    /// macOS Privacy settings deny the app the device outright. A stored
    /// allow cannot fix that; the card points at System Settings instead.
    var systemMicDenied = false
    var systemCameraDenied = false

    /// Device verdicts macOS reports for capture kinds. Display capture has
    /// no TCC gate: the system picker answers per share.
    static func systemDenials() -> (mic: Bool, camera: Bool) {
        let audio = AVCaptureDevice.authorizationStatus(for: .audio)
        let video = AVCaptureDevice.authorizationStatus(for: .video)
        return (
            mic: audio == .denied || audio == .restricted,
            camera: video == .denied || video == .restricted
        )
    }
}

/// Small centered card for a site's camera and microphone state, presented
/// by Mijick/Popups like the window-size card.
///
/// Window-level: the host fills the whole content view rather than one page
/// pane. Public WebKit offers no handle on a running capture, so this card
/// answers requests and remembers verdicts — it cannot mute mid-call, and
/// the footnote says revoking means reloading. Screen sharing never reaches
/// this card: the system picker answers it per share.
struct MediaCapturePopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    let snapshot: MediaCaptureSnapshot

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.clear)
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            MediaCapturePopupCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        MediaCaptureCard(
            snapshot: snapshot,
            onDecide: { kind, decision in
                MediaCapturePopupCoordinator.shared.decide(id: popupID, kind: kind, decision: decision)
            },
            onReload: {
                MediaCapturePopupCoordinator.shared.reload(id: popupID)
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

/// The rows themselves, shown inside the card above (or any other host,
/// previews and tests included).
struct MediaCaptureCard: View {
    let snapshot: MediaCaptureSnapshot
    var onDecide: ((AppSettings.MediaCaptureKind, AppSettings.MediaCaptureDecision) -> Void)?
    var onReload: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Mirrors the snapshot, updated optimistically as verdicts go out: the
    /// tab's live state is not observable from a `Sendable` card.
    @State private var pending: Set<AppSettings.MediaCaptureKind>
    @State private var granted: Set<AppSettings.MediaCaptureKind>

    init(
        snapshot: MediaCaptureSnapshot,
        onDecide: ((AppSettings.MediaCaptureKind, AppSettings.MediaCaptureDecision) -> Void)? = nil,
        onReload: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        _pending = State(initialValue: snapshot.pending)
        _granted = State(initialValue: snapshot.granted)
        self.onDecide = onDecide
        self.onReload = onReload
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(spacing: 10) {
                ForEach(AppSettings.MediaCaptureKind.allCases) { kind in
                    kindRow(kind)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.host)
                .font(.system(size: 13, weight: .semibold))
            Text(pending.isEmpty ? "Capture devices" : "Wants to use your devices")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func kindRow(_ kind: AppSettings.MediaCaptureKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(kind.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(statusText(for: kind))
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor(for: kind))
            }
            if systemBlocked(kind) {
                Text("macOS is blocking this device — allow Whatever in System Settings, Privacy & Security.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Picker("For \(kind.title)", selection: decisionBinding(for: kind)) {
                ForEach(AppSettings.MediaCaptureDecision.allCases) { decision in
                    Text(decision.title).tag(decision)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func statusText(for kind: AppSettings.MediaCaptureKind) -> String {
        if pending.contains(kind) { return "Waiting for your answer" }
        if granted.contains(kind) { return "In use" }
        return "Not requested"
    }

    private func statusColor(for kind: AppSettings.MediaCaptureKind) -> Color {
        if pending.contains(kind) { return .orange }
        if granted.contains(kind) { return .green }
        return .secondary
    }

    private func systemBlocked(_ kind: AppSettings.MediaCaptureKind) -> Bool {
        switch kind {
        case .microphone: snapshot.systemMicDenied
        case .camera: snapshot.systemCameraDenied
        }
    }

    private func decisionBinding(
        for kind: AppSettings.MediaCaptureKind
    ) -> Binding<AppSettings.MediaCaptureDecision> {
        // Pending rows answer for the frame that asked, not the top page.
        let host = snapshot.requestHosts[kind] ?? snapshot.host
        return Binding(
            get: {
                SettingsStore.shared.settings.mediaCapture.decision(for: host, kind: kind)
            },
            set: { decision in
                // Optimistic mirror: the verdict answers a held request now,
                // and the tab's publishers confirm it right after.
                if decision == .allow {
                    pending.remove(kind)
                    granted.insert(kind)
                } else if decision == .block {
                    pending.remove(kind)
                }
                onDecide?(kind, decision)
            }
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(footnote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Button("Close") {
                    onCancel?()
                }
                .controlSize(.small)
                Spacer()
                Button("Reload Page") {
                    onReload?()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footnote: String {
        if snapshot.isPrivate {
            return "Private tab: choices apply once and are never remembered. Reloading the page ends any live capture."
        }
        return "Choices are remembered for this site. Blocking or allowing applies when the page next asks — reloading ends any live capture."
    }
}

/// Root view hosted inside a window's content view: registers the popup
/// stack, then presents the card once the stack is on screen.
struct MediaCaptureRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let snapshot: MediaCaptureSnapshot

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
                await MediaCapturePopup(stackID: stackID, popupID: popupID, snapshot: snapshot)
                    .present(popupStackID: stackID)
            }
    }
}

/// Bridges one window to Mijick/Popups for the capture card.
///
/// Holds the tab and pane weakly: either may go away while the card is up
/// (tab closed, pane rebuilt), and a verdict then has nowhere to go, so it
/// is dropped. Dismissal is owned here for Escape and window teardown;
/// Mijick-driven dismissal reports back through the coordinator.
@MainActor
final class MediaCapturePresenter {
    private weak var container: NSView?
    private weak var tab: BrowserTab?
    private weak var pane: BrowserPaneController?
    private var hostingView: NSHostingView<MediaCaptureRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?
    private var onDidDismiss: (() -> Void)?

    init(
        container: NSView,
        tab: BrowserTab,
        pane: BrowserPaneController,
        onDidDismiss: (() -> Void)? = nil
    ) {
        self.container = container
        self.tab = tab
        self.pane = pane
        self.onDidDismiss = onDidDismiss
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    func present() {
        guard let container, let tab, let pane else { return }
        resetForReuse()

        let state = tab.tabController.captureState
        let denials = MediaCaptureSnapshot.systemDenials()
        let snapshot = MediaCaptureSnapshot(
            host: tab.displayURL.host?.lowercased() ?? "This page",
            isPrivate: tab.privacyMode == .privateBrowsing,
            pending: state.requests,
            granted: state.grants,
            requestHosts: pane.pendingCaptureHosts(),
            systemMicDenied: denials.mic,
            systemCameraDenied: denials.camera
        )
        let stackID = PopupStackID(rawValue: "media-capture-\(UUID().uuidString)")
        let popupID = "media-capture"
        let root = MediaCaptureRootView(stackID: stackID, popupID: popupID, snapshot: snapshot)
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
        MediaCapturePopupCoordinator.shared.registerDecide(id: popupID) { [weak self] kind, decision in
            self?.decide(kind: kind, decision: decision)
        }
        MediaCapturePopupCoordinator.shared.registerReload(id: popupID) { [weak self] in
            self?.reloadAndDismiss()
        }
        MediaCapturePopupCoordinator.shared.registerDismiss(id: popupID) { [weak self] in
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

    /// Answers a held request and, for regular tabs, remembers the verdict.
    /// `.ask` clears any stored verdict back to asking; a request still
    /// waiting stays waiting.
    private func decide(
        kind: AppSettings.MediaCaptureKind,
        decision: AppSettings.MediaCaptureDecision
    ) {
        guard let tab, let pane else { return }
        switch decision {
        case .allow:
            pane.resolveCapture(kind: kind, granted: true, persist: tab.privacyMode == .regular)
        case .block:
            pane.resolveCapture(kind: kind, granted: false, persist: tab.privacyMode == .regular)
        case .ask:
            if tab.privacyMode == .regular,
               let host = tab.displayURL.host?.lowercased(),
               !host.isEmpty
            {
                SettingsStore.shared.update {
                    $0.mediaCapture.setDecision(.ask, for: host, kind: kind)
                }
            }
        }
    }

    /// Reloading ends every live capture, so the card's job is done with it.
    private func reloadAndDismiss() {
        tab?.tabController.reload()
        dismiss()
    }

    /// Single teardown path, whether dismissal came from the host (Close,
    /// Reload, Escape), from Mijick's tap-outside layer, or from the shield
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

/// Routes Mijick's popup lifecycle callbacks and the card's verdicts back
/// to the presenter that owns the hosting view. Popup structs must stay
/// `Sendable`, so they cannot hold the presenter directly.
@MainActor
final class MediaCapturePopupCoordinator {
    static let shared = MediaCapturePopupCoordinator()

    private var decideHandlers: [String: (AppSettings.MediaCaptureKind, AppSettings.MediaCaptureDecision) -> Void] = [:]
    private var reloadHandlers: [String: () -> Void] = [:]
    private var dismissHandlers: [String: () -> Void] = [:]

    func registerDecide(
        id: String,
        handler: @escaping (AppSettings.MediaCaptureKind, AppSettings.MediaCaptureDecision) -> Void
    ) {
        decideHandlers[id] = handler
    }

    func registerReload(id: String, handler: @escaping () -> Void) {
        reloadHandlers[id] = handler
    }

    func registerDismiss(id: String, handler: @escaping () -> Void) {
        dismissHandlers[id] = handler
    }

    func decide(id: String, kind: AppSettings.MediaCaptureKind, decision: AppSettings.MediaCaptureDecision) {
        decideHandlers[id]?(kind, decision)
    }

    func reload(id: String) {
        reloadHandlers[id]?()
    }

    func popupDidDismiss(id: String) {
        decideHandlers.removeValue(forKey: id)
        reloadHandlers.removeValue(forKey: id)
        dismissHandlers.removeValue(forKey: id)?()
    }
}
