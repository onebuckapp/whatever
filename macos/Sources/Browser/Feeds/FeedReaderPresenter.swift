import AppKit
import Foundation
import MijickPopups
import SwiftUI
import WebKit

/// Shared reader state and navigation callbacks.
///
/// Popups must stay `Sendable`, so the view reaches navigation through this
/// coordinator rather than holding window callbacks itself.
@MainActor
final class FeedReaderCoordinator: ObservableObject {
    static let shared = FeedReaderCoordinator()

    let store = FeedReaderStore()

    /// Opens an article URL. `true` means a new tab; false means the selected tab.
    var onOpenArticle: ((URL, Bool) -> Void)?

    private var dismissHandlers: [String: () -> Void] = [:]

    private init() {}

    func register(id: String, handler: @escaping () -> Void) {
        dismissHandlers[id] = handler
    }

    func popupDidDismiss(id: String) {
        dismissHandlers.removeValue(forKey: id)?()
    }
}

/// The reader card, styled like the app's other centered cards.
struct FeedReaderPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.black.opacity(0.38))
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            FeedReaderCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        FeedReaderView()
            .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
            .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
            // Mijick masks the whole popup to its measured bounds, so the
            // shadows need transparent room around the card.
            .padding(.vertical, 88)
            .onTapGesture {}
            .onExitCommand {
                Task {
                    await PopupStack.dismissPopup(popupID, popupStackID: stackID)
                }
            }
    }
}

/// Root view hosted inside the window's content view.
struct FeedReaderRootView: View {
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
                await FeedReaderPopup(stackID: stackID, popupID: popupID)
                    .present(popupStackID: stackID)
            }
    }
}

/// Bridges one window to Mijick/Popups for the reader card.
@MainActor
final class FeedReaderPresenter {
    private weak var container: NSView?
    private var hostingView: NSHostingView<FeedReaderRootView>?
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

    /// Prepares the shared reader around one page's candidates, then shows the
    /// card over the window.
    func present(
        candidates: [FeedCandidate],
        pageURL: URL?,
        siteName: String?,
        webView: WKWebView?,
        allowsPersistence: Bool,
        onOpenArticle: ((URL, Bool) -> Void)?
    ) {
        guard let container else { return }
        resetForReuse()
        FeedReaderCoordinator.shared.onOpenArticle = onOpenArticle
        Task {
            await FeedReaderCoordinator.shared.store.present(
                candidates: candidates,
                pageURL: pageURL,
                siteName: siteName,
                webView: webView,
                allowsPersistence: allowsPersistence
            )
        }

        let stackID = PopupStackID(rawValue: "feed-reader-\(UUID().uuidString)")
        let popupID = "feed-reader"
        let root = FeedReaderRootView(stackID: stackID, popupID: popupID)
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
        FeedReaderCoordinator.shared.register(id: popupID) { [weak self] in
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

    private func tearDown() {
        resetForReuse()
        let notify = onDidDismiss
        onDidDismiss = nil
        notify?()
    }

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
