import AppKit
import Foundation
import MijickPopups
import SwiftUI

/// Bridges one page pane to Mijick/Popups for download history.
///
/// Same shape as the file browser presenter: the hosting view fills the
/// pane's page container so the popup centers on the webpage, and dismissal —
/// tap outside, Escape, close, or a new presentation — always tears down in
/// the same order. The store is fresh per presentation, so reopening never
/// shows the previous open's stale rows. Opening marks every finished
/// download seen, which clears the toolbar badge.
@MainActor
final class DownloadsPresenter {
    private weak var container: NSView?
    private weak var area: NSView?
    private var hostingView: NSHostingView<DownloadsPopupRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?
    private var onDidDismiss: (() -> Void)?
    private var store: DownloadsStore?

    init(container: NSView, area: NSView, onDidDismiss: (() -> Void)? = nil) {
        self.container = container
        self.area = area
        self.onDidDismiss = onDidDismiss
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    /// Shows download history over the page. Retrying a failed row dismisses
    /// first and reports through `onRetry`, so the card is never left
    /// covering the page its retry just navigated.
    func present(onRetry: @escaping (URL) -> Void) {
        guard let container, let area,
              area.isDescendant(of: container), container.window != nil
        else {
            return
        }
        resetForReuse()
        let store = DownloadsStore()
        store.onRetry = { [weak self] url in
            self?.dismiss()
            onRetry(url)
        }
        self.store = store
        DownloadsBadgeCenter.shared.markAllSeen()
        let stackID = PopupStackID(rawValue: "downloads-\(UUID().uuidString)")
        let popupID = "downloads"
        let root = DownloadsPopupRootView(stackID: stackID, popupID: popupID, store: store)
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: area.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: area.bottomAnchor),
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
        DownloadsCoordinator.shared.register(id: popupID) { [weak self] in
            self?.cleanup()
        }
    }

    /// Reloads the open history, reporting whether one was open. Behind ⌘R.
    @discardableResult
    func refresh() -> Bool {
        guard isPresented else { return false }
        store?.refresh()
        return true
    }

    func dismiss() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        cleanup()
    }

    private func cleanup() {
        resetForReuse()
        store = nil
        onDidDismiss?()
        onDidDismiss = nil
    }

    /// Tears down any previous host without notifying the owner. Used when
    /// this same presenter is about to show a new popup: firing `onDidDismiss`
    /// here would clear the owner's reference to this presenter mid-present
    /// and orphan the new host.
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

/// Routes Mijick's dismissal callback back to the presenter that owns the
/// hosting view. Popup structs must stay `Sendable`, so they cannot hold the
/// presenter directly.
@MainActor
final class DownloadsCoordinator {
    static let shared = DownloadsCoordinator()

    private var handlers: [String: () -> Void] = [:]

    func register(id: String, handler: @escaping () -> Void) {
        handlers[id] = handler
    }

    func popupDidDismiss(id: String) {
        handlers.removeValue(forKey: id)?()
    }
}
