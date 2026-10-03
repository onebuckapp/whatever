import AppKit
import Foundation
import MijickPopups
import SwiftUI

/// Bridges one page pane to Mijick/Popups.
///
/// The hosting view fills the pane's page container, so the library centers
/// the popup on the webpage and its tap-outside handling covers the page.
/// The presenter owns dismissal for tab switches and layout changes, while
/// Mijick-driven dismissal reports back through the coordinator.
@MainActor
final class QRPopupPresenter {
    private weak var container: NSView?
    private weak var area: NSView?
    private var hostingView: NSHostingView<QRPopupRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?
    private var onDidDismiss: (() -> Void)?

    init(container: NSView, area: NSView, onDidDismiss: (() -> Void)? = nil) {
        self.container = container
        self.area = area
        self.onDidDismiss = onDidDismiss
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    /// Shows the QR card for `text`.
    ///
    /// The symbol is encoded by the Nim backend, which now lives in the
    /// `WhateverStore` XPC service, so the encode is a round trip rather than a
    /// synchronous call. The card appears once the document is back; a payload
    /// the core refuses keeps the page untouched and just beeps.
    ///
    /// `isPresenting` guards against a second request racing the first, which
    /// would otherwise queue two encodes and leave an orphan card behind.
    private(set) var isPresenting = false

    /// Set while a dismissal is in progress, so an encode that lands afterwards
    /// does not reopen the card.
    private var isDismissed = false

    func present(text: String) {
        guard !isPresenting, let container, let area else { return }
        isPresenting = true

        Task { @MainActor [weak self] in
            let svg: String
            do {
                svg = try await BrowserCore.qrSVG(
                    for: text,
                    darkHex: QRCodeSVGColors.darkHex,
                    lightHex: QRCodeSVGColors.lightHex
                )
            } catch {
                self?.isPresenting = false
                SystemBeep.play()
                return
            }
            // The pane may have gone away, or been dismissed, while the encode
            // was in flight. `area` is the page container, which is a *child* of
            // `container` (the pane's root view), so the containment test has to
            // read the other way round: ask whether the page container is still
            // inside the pane, not whether the pane is inside its own page
            // container. Asking the second way is never true and silently
            // swallowed every presentation.
            guard let self, area.isDescendant(of: container), container.window != nil,
                  !isDismissed
            else {
                self?.isPresenting = false
                return
            }
            isPresenting = false
            install(svg: svg, text: text)
        }
    }

    private func install(svg: String, text: String) {
        guard let container, let area else { return }
        resetForReuse()
        isDismissed = false

        let stackID = PopupStackID(rawValue: "qr-\(UUID().uuidString)")
        let popupID = "qr-code"
        let root = QRPopupRootView(stackID: stackID, popupID: popupID, text: text, svg: svg)
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
        QRPopupCoordinator.shared.register(id: popupID) { [weak self] in
            self?.cleanup()
        }
    }

    func dismiss() {
        isDismissed = true
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        cleanup()
    }

    private func cleanup() {
        isDismissed = true
        resetForReuse()
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
final class QRPopupCoordinator {
    static let shared = QRPopupCoordinator()

    private var handlers: [String: () -> Void] = [:]

    func register(id: String, handler: @escaping () -> Void) {
        handlers[id] = handler
    }

    func popupDidDismiss(id: String) {
        handlers.removeValue(forKey: id)?()
    }
}
