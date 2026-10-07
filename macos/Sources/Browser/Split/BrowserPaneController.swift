import AppKit
import Combine
import WebKit

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
    private var pageBottomConstraint: NSLayoutConstraint?
    private var qrPopupPresenter: QRPopupPresenter?
    private var fileBrowserPresenter: FileBrowserPresenter?
    private var downloadsPresenter: DownloadsPresenter?
    private var findController: FindController?

    init(tab: BrowserTab, activeModel: ActivePaneModel) {
        self.tab = tab
        self.activeModel = activeModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        // A pane only exists for a tab the page area is showing, so asking the
        // tab to realize itself here is what builds the page. A restored tab
        // arrives without one.
        let webView = tab.ensureWebView()
        // This pane is also the `WKUIDelegate`. WebKit holds it weakly, and a
        // cross-site navigation replaces the view while this pane stays, so the
        // assignment belongs here rather than at construction: it is the moment a
        // view is known to have an owner willing to host a popup. Without it
        // WebKit has nobody to ask for a `target="_blank"` target and drops the
        // navigation without a word.
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(webView)

        NSLayoutConstraint.activate([
            pageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),

            webView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
        // Held rather than anonymous: the find bar deactivates this while it
        // is open and reactivates it on close, so the page holder yields its
        // bottom edge to the bar instead of overlapping it.
        let pageBottom = pageContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        pageBottom.isActive = true
        pageBottomConstraint = pageBottom

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

    // MARK: - File browser

    /// Shows the native listing for `url` over this pane's page. The tab
    /// itself does not navigate: directories are browsed in the popup and
    /// only files chosen there become real navigations, so directory
    /// browsing leaves no history behind.
    func presentFileBrowser(url: URL) {
        guard let pageContainer else { return }
        // Reopening on an already-visible popup reloads it in place rather
        // than stacking a second card: the path belongs to this press.
        if let fileBrowserPresenter, fileBrowserPresenter.isPresented {
            dismissFileBrowser()
        }
        let presenter = FileBrowserPresenter(container: view, area: pageContainer) { [weak self] in
            self?.fileBrowserPresenter = nil
        }
        fileBrowserPresenter = presenter
        presenter.present(directory: url.path) { [weak self] fileURL in
            self?.tab.navigate(to: fileURL)
        }
    }

    func dismissFileBrowser() {
        fileBrowserPresenter?.dismiss()
        fileBrowserPresenter = nil
    }

    /// Reloads the open listing for ⌘R, reporting whether one was open.
    /// A listing has no cache, so origin reloads land here too.
    @discardableResult
    func refreshFileBrowser() -> Bool {
        guard let fileBrowserPresenter, fileBrowserPresenter.isPresented else { return false }
        fileBrowserPresenter.refresh()
        return true
    }

    // MARK: - Downloads

    /// Shows download history over this pane's page. Retrying a failed row
    /// navigates this pane's tab to the source, which routes back through
    /// the download policy and records a fresh row.
    func presentDownloads() {
        guard let pageContainer else { return }
        // Like the file browser: reopening reloads in place rather than
        // stacking a second card.
        if let downloadsPresenter, downloadsPresenter.isPresented {
            dismissDownloads()
        }
        let presenter = DownloadsPresenter(container: view, area: pageContainer) { [weak self] in
            self?.downloadsPresenter = nil
        }
        downloadsPresenter = presenter
        presenter.present { [weak self] url in
            self?.tab.navigate(to: url)
        }
    }

    func dismissDownloads() {
        downloadsPresenter?.dismiss()
        downloadsPresenter = nil
    }

    /// Reloads the open history for ⌘R, reporting whether one was open.
    @discardableResult
    func refreshDownloads() -> Bool {
        guard let downloadsPresenter, downloadsPresenter.isPresented else { return false }
        downloadsPresenter.refresh()
        return true
    }

    // MARK: - Find in page

    /// Opens this pane's find bar, creating it on first use. The controller
    /// persists with the pane, so each tab keeps its own query while its pane
    /// sits in the window's cache.
    func showFindBar() {
        guard let pageContainer, let pageBottomConstraint else { return }
        if findController == nil {
            findController = FindController(
                tab: tab,
                container: view,
                pageContainer: pageContainer,
                pageBottomConstraint: pageBottomConstraint
            )
        }
        findController?.show()
    }

    /// Steps the current match, opening the bar first when it is closed so
    /// ⌘G never silently does nothing.
    func findStep(_ delta: Int) {
        showFindBar()
        findController?.step(delta)
    }

    // MARK: - Page context menu

    /// Uses the page the user is looking at, not the tab's last committed
    /// navigation, so the code matches what is on screen.
    private func presentPageQRCode() {
        // The page this pane is hosting, which is realized by now: a pane only
        // exists for a tab the page area is showing.
        presentQRCode(text: tab.webView?.url?.absoluteString ?? "")
    }

    private func updateBorder(activeID: UUID?, showsIndicator: Bool) {
        let isActive = showsIndicator && activeID == tab.id
        pageContainer?.layer?.borderColor = isActive
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
    }
}

extension BrowserPaneController: WKUIDelegate {
    /// Popups are handled in `NavigationController`, not here.
    ///
    /// WebKit offers a new-window navigation two ways: as this delegate call, and
    /// as a `decidePolicyFor` whose `targetFrame` is nil. Both describe the same
    /// click, and taking only this one loses the other: a page that calls
    /// `window.open` never reaches here, so it silently does nothing.
    ///
    /// Returning a view also hands WebKit the navigation, and it performs that
    /// navigation after this method returns — by which point the new tab is
    /// already selected, hosted, and loading whatever address it was born with.
    /// Measured: the popup tab arrived on the homepage instead of the page that
    /// opened it. Opening the tab from the policy callback instead means the
    /// address is known before anything is built, and there is no race.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    /// A page closing itself with `window.close()`.
    ///
    /// Only a popup ever reaches this: a page WebKit did not open has nothing to
    /// close, and WebKit does not ask.
    func webViewDidClose(_ webView: WKWebView) {
        let controller = BrowserCoordinator.shared.controller(for: view.window)
            ?? BrowserCoordinator.shared.keyController
        controller?.closePopupTab(webView)
    }

    /// The site a dialog should name as its speaker.
    ///
    /// Falls back to the page's title and then to a constant, because an
    /// `NSAlert` with an empty heading is worse than an unhelpful one. Hostless
    /// pages (`whtvr://about`, `about:blank`) have no site to name, so the title
    /// is the best available answer and the constant is the floor.
    ///
    /// Takes a plain `WKWebView` rather than the subclass because the delegate
    /// methods hand over whatever WebKit is holding.
    private func hostLabel(of webView: WKWebView) -> String {
        if let host = webView.url?.host, !host.isEmpty { return host }
        if let title = webView.title, !title.isEmpty { return title }
        return "This page"
    }

    // MARK: - JavaScript dialogs and file input

    // WebKit has no default presentation for these on macOS, so a page that calls
    // `alert()` without one of these implemented hangs the run loop with nothing
    // on screen. Each hands off to a real sheet and answers on the page's thread.

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = hostLabel(of: webView)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        sheet(alert, on: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = hostLabel(of: webView)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        sheet(alert, on: webView) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = hostLabel(of: webView)
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        sheet(alert, on: webView) { response in
            // A cancelled prompt is a nil answer, which is what the page reads as
            // its `prompt()` returning null. Submitting an empty string would be a
            // different thing entirely.
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// `<input type="file">`. Without this the page's file chooser never appears
    /// and the input reports an empty selection.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canCreateDirectories = false
        // `WKOpenPanelParameters` carries only those two flags on macOS — no title
        // and no accept label — so the panel keeps its own.
        panel.prompt = "Open"

        guard let window = webView.window else {
            completionHandler(nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    /// Shows `alert` as a sheet on the window showing `webView` and calls `finish`
    /// with the answer.
    ///
    /// A view with no window is answered rather than shown: `runModal` would block
    /// the very run loop that is supposed to be delivering the answer, and
    /// `beginSheetModal` needs a window to hang the sheet on. Both callers supply
    /// the answer a dismissed dialog would have given, which is the honest result
    /// for a page nobody can see.
    private func sheet(
        _ alert: NSAlert,
        on webView: WKWebView,
        _ finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard let window = webView.window else {
            finish(.alertSecondButtonReturn)
            return
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }
}
