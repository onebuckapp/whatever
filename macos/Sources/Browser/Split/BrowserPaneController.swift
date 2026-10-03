import AppKit
import Combine
import WebKit

/// TEMPORARY leak probes: query from lldb. Remove before finishing.
var paneProbeBirths = 0
var paneProbeDeaths = 0

/// Displays one tab: a page container that hosts the tab's existing
/// `WKWebView`. The container sits flush under the tab bar with square
/// top corners, so the page reads as attached to the bar; the bottom
/// corners stay rounded. Also the `WKUIDelegate` for that web
/// view, so `target="_blank"` and `window.open()` become new tabs in
/// the same window.
final class BrowserPaneController: NSViewController {
    let tab: BrowserTab
    private let activeModel: ActivePaneModel
    private var activeCancellable: AnyCancellable?
    private var pageContainer: NSView?
    private var qrPopupPresenter: QRPopupPresenter?

    init(tab: BrowserTab, activeModel: ActivePaneModel) {
        self.tab = tab
        self.activeModel = activeModel
        super.init(nibName: nil, bundle: nil)
        // TEMPORARY leak probe.
        paneProbeBirths += 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // TEMPORARY leak probe.
    deinit {
        paneProbeDeaths += 1
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let pageContainer = NSView()
        pageContainer.wantsLayer = true
        pageContainer.layer?.cornerRadius = 10
        // Square top corners meet the tab bar above; only the bottom
        // corners are rounded. This view is not flipped, so the visual
        // bottom is minY.
        pageContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        pageContainer.layer?.masksToBounds = true
        pageContainer.layer?.borderWidth = 1.5
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageContainer)
        self.pageContainer = pageContainer

        let webView = tab.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(webView)

        NSLayoutConstraint.activate([
            pageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            pageContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),

            webView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])

        activeCancellable = activeModel.$activeTabID
            .combineLatest(activeModel.$showsIndicator)
            .sink { [weak self] activeID, showsIndicator in
                self?.updateBorder(activeID: activeID, showsIndicator: showsIndicator)
            }
        updateBorder(activeID: activeModel.activeTabID, showsIndicator: activeModel.showsIndicator)

        // The web view injects the item into WebKit's own menu and calls
        // back here when it is chosen.
        if let webView = tab.webView as? BrowserWebView {
            webView.onGenerateQRCode = { [weak self] in
                self?.presentPageQRCode()
            }
        }
    }

    // MARK: - QR code

    /// Shows the QR card over this pane's page. The symbol is encoded by the
    /// Nim backend and rendered from its SVG document; the presenter owns
    /// presentation and dismissal.
    func presentQRCode(text: String) {
        guard !text.isEmpty else {
            SystemBeep.play()
            return
        }
        guard let pageContainer else { return }
        // Mijick ignores a repeated presentation of the same popup type, so
        // an already-visible card is simply left alone.
        if let qrPopupPresenter, qrPopupPresenter.isPresented {
            return
        }
        let presenter = QRPopupPresenter(container: view, area: pageContainer) { [weak self] in
            self?.qrPopupPresenter = nil
        }
        qrPopupPresenter = presenter
        presenter.present(text: text)
    }

    func dismissQRCode() {
        qrPopupPresenter?.dismiss()
        qrPopupPresenter = nil
    }

    // MARK: - Page context menu

    /// Uses the page the user is looking at, not the tab's last committed
    /// navigation, so the code matches what is on screen.
    private func presentPageQRCode() {
        presentQRCode(text: tab.webView.url?.absoluteString ?? "")
    }

    private func updateBorder(activeID: UUID?, showsIndicator: Bool) {
        let isActive = showsIndicator && activeID == tab.id
        pageContainer?.layer?.borderColor = isActive
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
    }
}

extension BrowserPaneController: WKUIDelegate {
    @MainActor
    /// Returning the new tab's web view lets WebKit perform the
    /// navigation into it, so popups land in a real tab.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let controller = BrowserCoordinator.shared.controller(for: view.window)
            ?? BrowserCoordinator.shared.keyController
        guard let newTab = BrowserCoordinator.shared.newTab(
            url: nil,
            privacyMode: tab.privacyMode,
            in: controller
        ) else {
            return nil
        }
        return newTab.webView
    }
}
