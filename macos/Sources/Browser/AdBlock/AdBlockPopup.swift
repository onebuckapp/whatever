import AppKit
import MijickPopups
import SwiftUI

/// Per-site content-blocker card: the current host, whether blocking applies
/// to it, and a way into the full Content Blocker settings.
///
/// Presented by Mijick/Popups like the QR card: a small centered card over a
/// transparent backdrop, tap-outside to dismiss. Shielded like every other
/// card while up, so the page underneath goes inert and an outside press
/// dismisses the card instead of reaching the page.
struct AdBlockPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    /// Lowercased page host the card opened on, or nil for pages without
    /// one (homepage, empty tabs), where there is nothing to except.
    let host: String?

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.clear)
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            AdBlockPopupCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        AdBlockPopupCard(host: host) {
            Task { @MainActor in
                AdBlockPopupCoordinator.shared.manageTapped(id: popupID)
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
        // Consume taps on the card itself, as every sibling card does, so a
        // click on empty card space cannot reach the tap-outside layer.
        // Deliberately a no-op rather than a dismissal like the QR card's:
        // this card holds live controls, and clicking them must not close it.
        .onTapGesture {}
        .onExitCommand {
            Task {
                await PopupStack.dismissPopup(popupID, popupStackID: stackID)
            }
        }
    }
}

/// The card itself: an ordinary view, so it can observe the settings store
/// and own the toggle binding. The popup struct above stays `Sendable` with
/// lets only.
private struct AdBlockPopupCard: View {
    @ObservedObject private var store = SettingsStore.shared

    /// Lowercased page host, or nil where there is nothing to except.
    let host: String?
    /// Called for the manage button, so the presenter can trade this card
    /// for the full settings tab.
    let onManage: () -> Void

    /// Effective blocking for the page, following parent entries too: a
    /// subdomain of an excepted host reads as paused even without its own
    /// entry.
    private var isBlocking: Bool {
        guard let host else { return false }
        return !ContentBlockerStore.isExcepted(
            host: host,
            in: store.settings.adblock.exceptions
        )
    }

    private var blockingBinding: Binding<Bool> {
        Binding(
            get: { isBlocking },
            set: { blocking in
                guard let host else { return }
                // Exact host only: removing a subdomain entry cannot lift a
                // parent exception, and the binding recomputes from the
                // effective state, so the toggle never lies about it.
                store.update { document in
                    if blocking {
                        document.adblock.exceptions.remove(host)
                    } else {
                        document.adblock.exceptions.insert(host)
                    }
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isBlocking ? "shield.fill" : "shield.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(isBlocking ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host ?? "This page")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(host == nil
                        ? "Open a website to manage it here."
                        : (isBlocking ? "Ads and trackers are blocked here."
                            : "Paused on this site."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Toggle("Block ads and trackers on this site", isOn: blockingBinding)
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(host == nil)
            Divider()
            Button(action: onManage) {
                HStack {
                    Text("Content Blocker settings")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }
}

/// Root view hosted in the window content.
///
/// Fills the window so the card centres over the whole window and
/// tap-outside covers the page, matching how the settings modal behaves.
struct AdBlockPopupRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let host: String?

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
                await AdBlockPopup(
                    stackID: stackID,
                    popupID: popupID,
                    host: host
                )
                .present(popupStackID: stackID)
            }
    }
}

/// Routes Mijick's callbacks back to the presenter that owns the hosting
/// view. Popup structs must stay `Sendable`, so they cannot hold the
/// presenter directly; the manage tap travels the same road as dismissal.
@MainActor
final class AdBlockPopupCoordinator {
    static let shared = AdBlockPopupCoordinator()

    private var dismissHandlers: [String: () -> Void] = [:]
    private var manageHandlers: [String: () -> Void] = [:]

    func register(
        id: String,
        onDismiss: @escaping () -> Void,
        onManage: @escaping () -> Void
    ) {
        dismissHandlers[id] = onDismiss
        manageHandlers[id] = onManage
    }

    func popupDidDismiss(id: String) {
        dismissHandlers.removeValue(forKey: id)?()
        manageHandlers.removeValue(forKey: id)
    }

    func manageTapped(id: String) {
        manageHandlers.removeValue(forKey: id)?()
    }
}

/// Bridges the window to Mijick/Popups for the per-site card.
///
/// One presenter per window, owned by the content controller next to the
/// settings presenter. The card is transient — toggling writes the
/// exception into settings, whose fan-out reloads the affected pages —
/// so, like the settings modal, re-presenting while up toggles it closed.
@MainActor
final class AdBlockPopupPresenter {
    private weak var container: NSView?
    private var hostingView: NSHostingView<AdBlockPopupRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?
    private var onDidDismiss: (() -> Void)?
    private var onManage: (() -> Void)?

    init(
        container: NSView,
        onDidDismiss: (() -> Void)? = nil,
        onManage: (() -> Void)? = nil
    ) {
        self.container = container
        self.onDidDismiss = onDidDismiss
        self.onManage = onManage
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    /// Opens the card for `host`, or does nothing if it is already open.
    ///
    /// Re-opening while it is up would stack a second card on the same
    /// window, and Mijick does not collapse two popups of the same id.
    func present(host: String?) {
        guard let container, container.window != nil, !isPresented else { return }
        resetForReuse()

        let stackID = PopupStackID(rawValue: "adblock-\(UUID().uuidString)")
        let popupID = "adblock-\(UUID().uuidString)"
        let root = AdBlockPopupRootView(stackID: stackID, popupID: popupID, host: host)
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
                Task { @MainActor in
                    self.dismiss()
                }
                return nil
            }
            return event
        }
        AdBlockPopupCoordinator.shared.register(
            id: popupID,
            onDismiss: { [weak self] in self?.tearDown() },
            onManage: { [weak self] in self?.manage() }
        )
    }

    func dismiss() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        tearDown()
    }

    /// Trades the card for the full settings tab: dismiss first, then let
    /// the owner open settings, so the two never stack.
    ///
    /// The handler is captured before the dismiss, not after: teardown nils
    /// every handler, so reading it afterwards always finds nothing and the
    /// settings tap silently does nothing.
    func manage() {
        let manage = onManage
        onManage = nil
        dismiss()
        manage?()
    }

    /// Single teardown path, whether dismissal came from Escape, from
    /// Mijick's tap-outside layer, or from the owner.
    private func tearDown() {
        resetForReuse()
        let notify = onDidDismiss
        onDidDismiss = nil
        onManage = nil
        notify?()
    }

    /// Drops the host without notifying the owner, so a re-present cannot clear
    /// the owner's reference to this presenter mid-present.
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
