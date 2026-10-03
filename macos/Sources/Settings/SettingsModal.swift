import AppKit
import MijickPopups
import SwiftUI

/// The settings card: a fixed sidebar beside a scrolling detail pane.
///
/// Styled exactly like the QR card — same backdrop opacity, corner radius, two
/// shadows, and vertical padding for shadow room — so the two read as one family
/// of dialogs. The consuming tap gesture matters as much as the looks: without it
/// a click on empty card space falls through to Mijick's tap-outside layer and
/// closes the dialog the user was trying to click inside.
struct SettingsModalPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    let section: SettingsSection

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.black.opacity(0.38))
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            SettingsModalCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    /// Hands off to the card rather than hosting the layout here.
    ///
    /// The section being shown has to change while the card is up, and this struct
    /// cannot hold that state: Mijick presents one popup value and the struct has
    /// to stay `Sendable`, so its `section` is fixed for the popup's whole life.
    /// `SettingsModalCard` is an ordinary view and can own the selection.
    var body: some View {
        SettingsModalCard(stackID: stackID, popupID: popupID, section: section)
    }
}

/// The card itself: a fixed sidebar beside a scrolling detail pane.
///
/// Styled exactly like the QR card — same backdrop opacity, corner radius, two
/// shadows, and vertical padding for shadow room — so the two read as one family
/// of dialogs. The consuming tap gesture matters as much as the looks: without it
/// a click on empty card space falls through to Mijick's tap-outside layer and
/// closes the dialog the user was trying to click inside.
private struct SettingsModalCard: View {
    /// Left and right inset for the sidebar's own content.
    ///
    /// The sidebar's background is flush with the card's rounded left edge, so
    /// without a generous inset the first glyph of every row sits almost on the
    /// margin and the selection highlight looks like it is falling off the card.
    ///
    /// One constant for the heading and the rows so the two stay aligned; they are
    /// the same optical left edge.
    private static let rowInset: CGFloat = 18

    let stackID: PopupStackID
    let popupID: String

    /// Which pane the card opened on. The sidebar moves the selection from here.
    @State private var selected: SettingsSection

    init(stackID: PopupStackID, popupID: String, section: SettingsSection) {
        self.stackID = stackID
        self.popupID = popupID
        _selected = State(initialValue: section)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                SettingsDetailView.view(for: selected)
                    // One pane replaces the next, so the scroll offset belongs to
                    // the pane that is going away rather than carrying over.
                    .id(selected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
        // Mijick masks the whole popup to its measured bounds, so the shadows
        // need transparent room around the card. Symmetric, so the card itself
        // stays centered.
        .padding(.vertical, 88)
        .onTapGesture {}
        .onExitCommand {
            Task {
                await PopupStack.dismissPopup(popupID, popupStackID: stackID)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, Self.rowInset)
                .padding(.top, 14)
                .padding(.bottom, 8)
            ForEach(SettingsSection.allCases) { entry in
                row(entry)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 196)
        .padding(.bottom, 10)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// A sidebar row that switches the detail pane.
    ///
    /// Deliberately does *not* dismiss the card. Picking a section is navigation
    /// inside the dialog; closing it on every click meant the sidebar could only
    /// ever be used to reopen the modal on a different pane, which is not what a
    /// sidebar is for.
    private func row(_ entry: SettingsSection) -> some View {
        let isSelected = entry == selected
        return Button {
            selected = entry
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entry.symbol)
                    .frame(width: 16)
                Text(entry.title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, Self.rowInset)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Root view hosted in the window content.
///
/// Fills the window so the card centres over the whole window and tap-outside
/// covers the page, matching how the noise card and the QR card behave.
struct SettingsModalRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let section: SettingsSection

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
                await SettingsModalPopup(
                    stackID: stackID,
                    popupID: popupID,
                    section: section
                )
                .present(popupStackID: stackID)
            }
    }
}

/// Routes Mijick's dismissal callback back to the presenter that owns the
/// hosting view. Popup structs must stay `Sendable`, so they cannot hold the
/// presenter directly.
@MainActor
final class SettingsModalCoordinator {
    static let shared = SettingsModalCoordinator()

    private var dismissHandlers: [String: () -> Void] = [:]

    func register(id: String, handler: @escaping () -> Void) {
        dismissHandlers[id] = handler
    }

    func popupDidDismiss(id: String) {
        dismissHandlers.removeValue(forKey: id)?()
    }
}

/// Bridges the window to Mijick/Popups for the settings card.
///
/// One presenter per window. The window owns the modal's lifetime, so tab
/// switches and layout changes do not need to dismiss it the way the QR card
/// does, and Escape is the only host-side dismissal.
@MainActor
final class SettingsModalPresenter {
    private weak var container: NSView?
    private var hostingView: NSHostingView<SettingsModalRootView>?
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

    /// Opens the card on `section`, or does nothing if it is already open.
    ///
    /// Re-opening while it is up would stack a second card on the same window,
    /// and Mijick does not collapse two popups of the same id.
    func present(section: SettingsSection = .general) {
        guard let container, container.window != nil, !isPresented else { return }
        resetForReuse()

        let stackID = PopupStackID(rawValue: "settings-\(UUID().uuidString)")
        let popupID = "settings"
        let root = SettingsModalRootView(stackID: stackID, popupID: popupID, section: section)
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
        SettingsModalCoordinator.shared.register(id: popupID) { [weak self] in
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

    /// Single teardown path, whether dismissal came from Escape, from
    /// Mijick's tap-outside layer, or from the owner.
    private func tearDown() {
        resetForReuse()
        let notify = onDidDismiss
        onDidDismiss = nil
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