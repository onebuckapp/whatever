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
    private var radiusCancellable: AnyCancellable?
    private var themeCancellable: AnyCancellable?
    /// Resolved user-CSS overrides for the page card, applied in
    /// `applyPageAppearance` after the structured values.
    private var pageThemeProps: [String: String] = [:]
    private var themeGeneration = 0
    private var pageContainer: NSView?
    private var pageBottomConstraint: NSLayoutConstraint?
    private var pageLeadingConstraint: NSLayoutConstraint?
    private var pageTrailingConstraint: NSLayoutConstraint?
    private var qrPopupPresenter: QRPopupPresenter?
    private var suggestPresenter: PasswordSuggestPresenter?
    private var fileBrowserPresenter: FileBrowserPresenter?
    private var downloadsPresenter: DownloadsPresenter?
    private var findController: FindController?
    private var linkHoverBubble: LinkHoverBubble?
    private var pdfController: PDFViewerController?
    /// Follows the tab's viewer state, so a PDF finishing loading (or
    /// failing) re-hosts without anyone asking.
    private var pdfCancellable: AnyCancellable?
    private var clickMonitor: Any?
    /// A verdict awaiting the user. One instance can sit under two kinds (a
    /// combined camera+mic request answers both with one decision), so
    /// answering goes through `resolve`, which delivers the held decision
    /// exactly once no matter how many kinds point at it.
    private final class PendingCaptureRequest {
        let kinds: Set<AppSettings.MediaCaptureKind>
        /// Siblings a combined request already cleared by stored verdict,
        /// granted alongside when the answer grants.
        let preGranted: Set<AppSettings.MediaCaptureKind>
        /// Origin host that asked. Verdicts persist under it rather than the
        /// top page, so an embedded frame's answer matches its next ask.
        let host: String
        private let answer: (WKPermissionDecision) -> Void
        private var answered = false

        init(
            kinds: Set<AppSettings.MediaCaptureKind>,
            preGranted: Set<AppSettings.MediaCaptureKind>,
            host: String,
            answer: @escaping (WKPermissionDecision) -> Void
        ) {
            self.kinds = kinds
            self.preGranted = preGranted
            self.host = host
            self.answer = answer
        }

        func resolve(_ decision: WKPermissionDecision) {
            guard !answered else { return }
            answered = true
            answer(decision)
        }
    }

    /// Capture verdicts awaiting the user, by kind.
    private var pendingCaptureRequests: [AppSettings.MediaCaptureKind: PendingCaptureRequest] = [:]
    /// Kinds a combined request already cleared by stored verdict, waiting
    /// on their sibling's answer. Marked granted only if the answer grants;
    /// a denial leaves them unnoted, which is the truth (nothing captured).
    private var preGrantedCaptureKinds: Set<AppSettings.MediaCaptureKind> = []
    /// Host the pending handlers above belong to. Any change answers them
    /// denied: their page is gone.
    private var lastCaptureHost: String?
    private var captureCancellable: AnyCancellable?

    /// A submitted login awaiting its verdict: the form's address plus the
    /// entered pair. Retired by the next committed navigation, which prompts
    /// a save when the landing left the form behind. Never persisted, never
    /// kept past one navigation.
    private struct PendingLogin {
        var formURL: URL
        var username: String
        var password: String
    }

    private var pendingLogin: PendingLogin?
    private var loginCancellable: AnyCancellable?
    private var credentialPicker: PasswordCredentialPickerPresenter?

    /// Where this pane sits: alone, or flush against its sibling in a split.
    ///
    /// A split reads as one grouped surface — `[ tab 1 | tab 2 ]` rather than
    /// `[ tab 1 ] [ tab 2 ]` — so the inner sides lose their margin and their
    /// corner radius, and the meeting borders form the separator. Set by the
    /// window controller whenever it rebuilds the page area.
    enum SplitPosition {
        case single, leading, trailing
    }

    var splitPosition: SplitPosition = .single {
        didSet { applySplitPosition() }
    }

    init(tab: BrowserTab, activeModel: ActivePaneModel) {
        self.tab = tab
        self.activeModel = activeModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        denyPendingCaptures()
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

        NSLayoutConstraint.activate([
            pageContainer.topAnchor.constraint(equalTo: view.topAnchor),
        ])
        pageLeadingConstraint = pageContainer.leadingAnchor.constraint(
            equalTo: view.leadingAnchor, constant: 6)
        pageLeadingConstraint?.isActive = true
        pageTrailingConstraint = pageContainer.trailingAnchor.constraint(
            equalTo: view.trailingAnchor, constant: -6)
        pageTrailingConstraint?.isActive = true

        // A pane only exists for a tab the page area is showing, so asking the
        // tab to realize itself here is what builds the page. A restored tab
        // arrives without one.
        hostPage()
        pdfCancellable = tab.tabController.$pdfState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hostPage() }
        // Held rather than anonymous: the find bar deactivates this while it
        // is open and reactivates it on close, so the page holder yields its
        // bottom edge to the bar instead of overlapping it.
        let pageBottom = pageContainer.bottomAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -Self.currentPageBottomInset)
        pageBottom.isActive = true
        pageBottomConstraint = pageBottom

        activeCancellable = activeModel.$activeTabID
            .combineLatest(activeModel.$showsIndicator)
            .sink { [weak self] activeID, showsIndicator in
                self?.updateBorder(activeID: activeID, showsIndicator: showsIndicator)
            }
        updateBorder(activeID: activeModel.activeTabID, showsIndicator: activeModel.showsIndicator)
        applySplitPosition()
        installClickToFocus()
        applyPageAppearance()
        // Page roundness from Settings: the radius, and whether the top
        // corners join it (pills) or meet the tab bar squarely (attached).
        // No half-height cap: the page is orders of magnitude larger than
        // any sane radius.
        radiusCancellable = SettingsStore.shared.$settings
            .map { ($0.appearance.pageCornerRadius, $0.appearance.tabShape, $0.appearance.tabPosition) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPageAppearance() }
        themeCancellable = ThemeEngine.shared.$fullCSS
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPageThemeStyles() }
        // Capture requests belong to a page, not to the tab in the
        // abstract: a navigation strands their handlers, so the leftovers
        // are answered denied here while the tab controller drops the
        // published requests the same way (see its host carrying).
        captureCancellable = tab.tabController.$url
            .map { $0?.host?.lowercased() }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] host in
                guard let self else { return }
                if host != lastCaptureHost {
                    lastCaptureHost = host
                    denyPendingCaptures()
                }
            }
        lastCaptureHost = tab.tabController.url?.host?.lowercased()
        // A submitted login belongs to the page that posted it: any
        // committed navigation retires it, prompting a save only when the
        // landing left the form behind (the success signal). The picker
        // anchors to a field rect that a navigation equally strands.
        loginCancellable = tab.tabController.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.noteLoginCommit(url)
            }
    }

    /// The page card's inset from the pane's bottom edge. Below the page the
    /// card meets attached cells flush and floats 7pt off a pill strip,
    /// while above the page it floats 6pt off the window and crawl edges.
    static func pageBottomInset(tabPosition: TabPosition, tabShape: TabShape) -> CGFloat {
        if tabPosition == .bottom {
            return tabShape == .attached ? 0 : 7
        }
        return 6
    }

    /// `pageBottomInset` for the stored settings.
    private static var currentPageBottomInset: CGFloat {
        let appearance = SettingsStore.shared.settings.appearance
        return pageBottomInset(tabPosition: appearance.tabPosition, tabShape: appearance.tabShape)
    }

    /// Applies the page card's roundness and the bottom inset that keeps it
    /// attached to the strip below. CSS overrides the radius while set and
    /// paints the card behind the (usually opaque) page, visible at rounded
    /// corners and wherever the page lets through.
    private func applyPageAppearance() {
        let structured = CGFloat(max(
            SettingsStore.shared.settings.appearance.pageCornerRadius, 0))
        pageContainer?.layer?.cornerRadius =
            ThemeStyleValue.length(pageThemeProps, "border-radius") ?? structured
        pageContainer?.layer?.maskedCorners = pageMaskedCorners()
        pageContainer?.layer?.backgroundColor =
            ThemeStyleValue.color(pageThemeProps, "background-color")?.cgColor
        pageBottomConstraint?.constant = -Self.currentPageBottomInset
    }

    /// Re-resolves user-CSS over the page node and repaints. The only page
    /// state is the focused split (`:active`); settings arrive through the
    /// stylesheet subscription.
    private func refreshPageThemeStyles() {
        themeGeneration += 1
        let current = themeGeneration
        var states: [String] = []
        if pageIsActiveForTheme { states.append("active") }
        let tree = [ThemeNode(
            key: "window", element: "window",
            children: [ThemeNode(
                key: "page", element: "page", id: "page", states: states)])]
        Task { [weak self] in
            let styles = await ThemeEngine.shared.resolve(nodes: tree)
            guard let self, current == self.themeGeneration else { return }
            self.pageThemeProps = styles["page"] ?? [:]
            self.applyPageAppearance()
        }
    }

    /// Whether this pane's tab is the focused one, mirrored from
    /// `updateBorder` so the `:active` state follows the accent border.
    private var pageIsActiveForTheme = false

    /// Which page corners round: the split owns the inner sides (flush and
    /// square where panes meet), the tab shape owns the page edge facing the
    /// tab bar (square while attached to it, rounded with the rest while
    /// pilled). Below the page the mirror holds: the bottom edge faces the
    /// bar. Read live from Settings, so both this and `applySplitPosition`
    /// converge whichever runs last.
    private func pageMaskedCorners() -> CACornerMask {
        let pills = SettingsStore.shared.settings.appearance.tabShape.roundsBottomCorners
        let tabsAtBottom = SettingsStore.shared.settings.appearance.tabPosition == .bottom
        switch splitPosition {
        case .single:
            return SettingsStore.shared.settings.appearance.tabShape.pageCorners(tabsAtBottom: tabsAtBottom)
        case .leading:
            if pills {
                return [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            }
            return tabsAtBottom ? [.layerMinXMaxYCorner] : [.layerMinXMinYCorner]
        case .trailing:
            if pills {
                return [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            }
            return tabsAtBottom ? [.layerMaxXMaxYCorner] : [.layerMaxXMinYCorner]
        }
    }

    /// Lays the page out for the current split position: flush inner sides
    /// with square corners in a split, full chrome alone. This view is not
    /// flipped, so the visual bottom is minY.
    private func applySplitPosition() {
        guard let pageContainer else { return }
        switch splitPosition {
        case .single:
            pageLeadingConstraint?.constant = 6
            pageTrailingConstraint?.constant = -6
        case .leading:
            pageLeadingConstraint?.constant = 6
            pageTrailingConstraint?.constant = 0
        case .trailing:
            pageLeadingConstraint?.constant = 0
            pageTrailingConstraint?.constant = -6
        }
        pageContainer.layer?.maskedCorners = pageMaskedCorners()
    }

    /// Clicking a pane's page focuses its tab, so the address bar and the
    /// active outline follow the pointer in a split. A local monitor rather
    /// than page script: it needs no cooperation from the site and fires for
    /// every press.
    ///
    /// The press must genuinely land on the page: hit-testing through the
    /// window's content view skips anything covered by a card, the shield,
    /// or the find bar, since those swallow the click before the page sees
    /// it and focusing underneath would both select a tab and hand it a
    /// click meant for the card. Already-selected tabs are left alone, so
    /// ordinary clicks never pay for a full switch.
    private func installClickToFocus() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.focusIfClicked(event)
            return event
        }
    }

    private func focusIfClicked(_ event: NSEvent) {
        guard let window = view.window,
              event.window === window,
              let contentView = window.contentView
        else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else { return }
        // The viewer counts as page content too: clicking a PDF in a split
        // focuses its tab like clicking a page does.
        let inWebView = tab.webView.map { hit === $0 || hit.isDescendant(of: $0) } ?? false
        let inPDF = (pdfController?.view).map { hit === $0 || hit.isDescendant(of: $0) } ?? false
        guard inWebView || inPDF else { return }
        guard let controller = BrowserCoordinator.shared.controller(for: window),
              controller.selectedTabID != tab.id
        else { return }
        controller.selectTab(tab)
    }

    /// Ensures the tab's page exists and is embedded in this pane.
    ///
    /// Waking a slept tab back up: selecting a tab whose view was discarded
    /// rebuilds it here and loads its address anew. No-op when the hosted
    /// view is current. Only called for displayed tabs — calling it for a
    /// hidden tab would realize a page nobody is looking at.
    ///
    /// A tab showing (or wanting) a PDF hosts the native viewer instead of
    /// a web view: WebKit never renders the document, so its built-in PDF
    /// toolbar never appears.
    func hostPage() {
        guard let pageContainer else { return }
        if tab.isPDF || tab.isPDFAddress {
            hostPDF()
            return
        }
        if pdfController?.view.superview != nil {
            pdfController?.view.removeFromSuperview()
        }
        let webView = tab.ensureWebView()
        // The menu items live on the view, so a rebuilt view needs rewiring;
        // reassigning the same closures onto the hosted view is harmless.
        if let browserView = webView as? BrowserWebView {
            browserView.onGenerateQRCode = { [weak self] url in
                self?.presentMenuQRCode(link: url)
            }
            browserView.onFullScreenCapture = { [weak self] in
                self?.presentFullScreenCapture()
            }
            browserView.onOpenLinkInNewTab = { [weak self] url in
                self?.openLinkInNewTab(url)
            }
            browserView.onOpenLinkInNewWindow = { [weak self] url in
                self?.openLinkInNewWindow(url)
            }
            browserView.onDownloadImage = { [weak self] url in
                self?.downloadImage(url)
            }
            browserView.onLinkHover = { [weak self] url in
                if let url {
                    self?.showLinkHover(url)
                } else {
                    self?.hideLinkHover()
                }
            }
            // Video reports belong to the tab, not the pane: the toolbar's
            // PiP button follows the tab controller's candidates.
            browserView.onVideoReport = { [weak self] report in
                self?.tab.tabController.noteVideoReport(report)
            }
            browserView.passwordMenuContextProvider = { [weak self] in
                guard let self else {
                    return PasswordMenuContext(isUnlocked: false, matches: [])
                }
                let store = PasswordStore.shared
                let host = PasswordAutofill.normalizeHost(url: self.tab.displayURL)
                guard !host.isEmpty else {
                    return PasswordMenuContext(
                        isUnlocked: store.lockState == .unlocked, matches: [])
                }
                return PasswordMenuContext(
                    isUnlocked: store.lockState == .unlocked,
                    matches: store.credentials(matchingHost: host)
                )
            }
            browserView.onFillCredential = { [weak self] siteID, credentialID in
                self?.fillCredential(siteID: siteID, credentialID: credentialID)
            }
            browserView.onSuggestPassword = { [weak self, weak browserView] in
                self?.openSuggestPanel(anchorView: browserView)
            }
            browserView.onPresentPasswordManager = { [weak self] in
                self?.presentPasswordManagerForMenu()
            }
            browserView.onLoginFieldFocus = { [weak self] kind, anchor in
                self?.loginFieldFocused(kind: kind, anchor: anchor)
            }
            browserView.onLoginSubmitted = { [weak self] username, password in
                self?.loginSubmitted(username: username, password: password)
            }
            // A re-hosted page carries no login state: a stale pending
            // submit or picker would name a form nobody is looking at.
            pendingLogin = nil
            credentialPicker?.dismiss()
            // A new (or re-shown) page carries no hover: a stale bubble would
            // name a link nobody is pointing at.
            hideLinkHover()
        }
        guard webView.superview !== pageContainer else { return }
        // This pane is also the `WKUIDelegate`. WebKit holds it weakly, and a
        // cross-site navigation replaces the view while this pane stays, so the
        // assignment belongs here rather than at construction: it is the moment a
        // view is known to have an owner willing to host a popup. Without it
        // WebKit has nobody to ask for a `target="_blank"` target and drops the
        // navigation without a word.
        webView.uiDelegate = self
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
    }

    // MARK: - PDF viewer

    /// Whether this pane is showing the native viewer rather than a page.
    var isShowingPDF: Bool {
        tab.isPDF
    }

    /// Embeds the native viewer for the tab's PDF, starting its fetch when
    /// the address has no content yet (a restored or woken tab). Idempotent:
    /// re-hosting the same state only re-renders, keeping zoom and scroll.
    private func hostPDF() {
        guard let pageContainer else { return }
        tab.ensurePDFContent()
        let controller: PDFViewerController
        if let existing = pdfController {
            controller = existing
        } else {
            let fresh = PDFViewerController()
            fresh.onRetry = { [weak self] in self?.tab.retryPDF() }
            pdfController = fresh
            controller = fresh
        }
        // Touches `viewDidLoad` before the first render.
        _ = controller.view
        controller.render(pdfContent())
        guard controller.view.superview !== pageContainer else { return }
        tab.webView?.removeFromSuperview()
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
    }

    /// The viewer's content for the tab's current viewer state. A tab whose
    /// address wants the viewer but has no state yet (restored, woken)
    /// reads as loading: the fetch `hostPDF` started fills it in.
    private func pdfContent() -> PDFViewerController.Content {
        switch tab.tabController.pdfState {
        case .none:
            return .loading(tab.currentURL)
        case .loading(let url):
            return .loading(url)
        case .ready(let document, let data, _, let filename):
            return .ready(document: document, data: data, filename: filename)
        case .failed(let url, let message):
            return .failed(url: url, message: message)
        }
    }

    /// Moves keyboard focus into whatever this pane shows: the viewer for a
    /// PDF tab, a (built if needed) web view otherwise. Unlike calling
    /// `ensureWebView` directly, this never builds a web view for a PDF.
    func focusContent() {
        if tab.isPDF || tab.isPDFAddress {
            hostPDF()
            view.window?.makeFirstResponder(pdfController?.focusView)
        } else if let window = view.window {
            window.makeFirstResponder(tab.ensureWebView())
        }
    }

    func pdfZoomIn() {
        pdfController?.zoomIn()
    }

    func pdfZoomOut() {
        pdfController?.zoomOut()
    }

    func pdfResetZoom() {
        pdfController?.resetZoom()
    }

    // MARK: - QR code

    /// Opens a context-menu link in a new tab of this window.
    ///
    /// A scheme the page cannot draw, such as mailto: or tel:, goes to the
    /// app that handles it instead — the same rule a `window.open` for one
    /// follows — rather than opening a tab that could never render it.
    /// Keyboard focus stays where it was: the menu, not the address field,
    /// was the explicit gesture.
    private func openLinkInNewTab(_ url: URL) {
        guard NavigationPolicy.canLoadInPage(URLRequest(url: url)) else {
            NavigationPolicy.handOffToSystem(url)
            return
        }
        let controller = BrowserCoordinator.shared.controller(for: view.window)
        BrowserCoordinator.shared.newTab(
            url: url,
            privacyMode: tab.privacyMode,
            in: controller,
            focusesAddressBar: false
        )
    }

    /// Opens a context-menu link in a new window.
    ///
    /// A private tab opens a private window: the coordinator's plain
    /// `newWindow(url:)` always builds a regular tab, which would leak the
    /// link out of the private session.
    private func openLinkInNewWindow(_ url: URL) {
        guard NavigationPolicy.canLoadInPage(URLRequest(url: url)) else {
            NavigationPolicy.handOffToSystem(url)
            return
        }
        if tab.privacyMode == .privateBrowsing {
            let fresh = BrowserTab(
                privacyMode: .privateBrowsing,
                profileID: tab.profileID,
                history: BrowserCoordinator.shared.history,
                initialURL: url
            )
            BrowserCoordinator.shared.newWindow(containing: fresh)
        } else {
            BrowserCoordinator.shared.newWindow(url: url)
        }
    }

    /// Downloads a context-menu image through the download pipeline, so it
    /// lands in the downloads folder and is recorded like any other
    /// download. WebKit's own item is retaken for this: left alone it saves
    /// without recording (why "Download Linked File" is removed outright),
    /// and declined it does nothing at all. `startDownload` hands back the
    /// transfer directly, so this needs no navigation policy — the adoption
    /// mirrors the policy-driven one.
    private func downloadImage(_ url: URL) {
        guard let webView = tab.webView else {
            SystemBeep.play()
            return
        }
        webView.startDownload(using: URLRequest(url: url)) { download in
            Task { @MainActor in
                DownloadsCenter.shared.adopt(WebDownload(
                    download: download,
                    sourceURL: url,
                    suggestedFilename: nil,
                    bytesExpected: -1
                ))
            }
        }
    }

    /// Where pane popup hosts live: the window content view, not this pane.
    ///
    /// Hosts must sit above the modal shield, which covers the whole content
    /// view, so a host inside the pane would leave its card visible but
    /// unclickable, every press landing on the shield instead. They are still
    /// constrained to this pane's page area, so each card centers on its own
    /// page. Nil while the pane is detached, when there is no window whose
    /// shield the card would need cover from.
    private var popupContainer: NSView? {
        view.window?.contentView
    }

    /// Shows the QR card over this pane's page. The symbol is encoded by the
    /// Nim backend and rendered from its SVG document; the presenter owns
    /// presentation and dismissal. Shielded like every other card while up:
    /// the transparent overlay makes the page inert and dismisses the card
    /// on an outside press.
    func presentQRCode(text: String) {
        guard !text.isEmpty else {
            SystemBeep.play()
            return
        }
        guard let pageContainer, let popupContainer else { return }
        // Mijick ignores a repeated presentation of the same popup type, so
        // an already-visible card is simply left alone.
        if let qrPopupPresenter, qrPopupPresenter.isPresented {
            return
        }
        let presenter = QRPopupPresenter(
            container: popupContainer,
            area: pageContainer,
            onDidDismiss: { [weak self] in
                self?.qrPopupPresenter = nil
                self?.releasePopupShield(id: "qr-code")
            },
            onDidPresent: { [weak self] in
                self?.claimPopupShield(id: "qr-code") { [weak self] in
                    self?.dismissQRCode()
                }
            }
        )
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
        guard let pageContainer, let popupContainer else { return }
        // Reopening on an already-visible popup reloads it in place rather
        // than stacking a second card: the path belongs to this press.
        if let fileBrowserPresenter, fileBrowserPresenter.isPresented {
            dismissFileBrowser()
        }
        let presenter = FileBrowserPresenter(container: popupContainer, area: pageContainer) { [weak self] in
            self?.fileBrowserPresenter = nil
            self?.releasePopupShield(id: "file-browser")
        }
        fileBrowserPresenter = presenter
        presenter.present(directory: url.path) { [weak self] fileURL in
            self?.tab.navigate(to: fileURL)
        }
        if presenter.isPresented {
            claimPopupShield(id: "file-browser") { [weak self] in
                self?.dismissFileBrowser()
            }
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
        guard let pageContainer, let popupContainer else { return }
        // Like the file browser: reopening reloads in place rather than
        // stacking a second card.
        if let downloadsPresenter, downloadsPresenter.isPresented {
            dismissDownloads()
        }
        let presenter = DownloadsPresenter(container: popupContainer, area: pageContainer) { [weak self] in
            self?.downloadsPresenter = nil
            self?.releasePopupShield(id: "downloads")
        }
        downloadsPresenter = presenter
        presenter.present { [weak self] url in
            self?.tab.navigate(to: url)
        }
        if presenter.isPresented {
            claimPopupShield(id: "downloads") { [weak self] in
                self?.dismissDownloads()
            }
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

    /// Claims the window shield for a popup hosted by this pane. The window
    /// owns the one shield view (it must sit below the toolbar), so the pane
    /// reaches it through the window controller; a missing window means the
    /// pane is detached and there is nothing to cover.
    private func claimPopupShield(id: String, dismiss: @escaping () -> Void) {
        guard let window = view.window else { return }
        BrowserCoordinator.shared.controller(for: window)?.claimPopupShield(id: id, onDismiss: dismiss)
    }

    private func releasePopupShield(id: String) {
        guard let window = view.window else { return }
        BrowserCoordinator.shared.controller(for: window)?.releasePopupShield(id: id)
    }

    // MARK: - Find in page

    /// Opens this pane's find bar, creating it on first use. The controller
    /// persists with the pane, so each tab keeps its own query while its pane
    /// sits in the window's cache. PDFs have no page to search: the bar is
    /// web-only, so it beeps there instead of opening onto nothing.
    func showFindBar() {
        guard !tab.isPDF else {
            SystemBeep.play()
            return
        }
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

    // MARK: - Link hover bubble

    /// Shows the hovered link's address in the floating bubble, creating it
    /// on first use. The bubble overlays the page's bottom-left corner
    /// rather than pushing the page up, and it never takes clicks.
    private func showLinkHover(_ url: URL) {
        guard let pageContainer else { return }
        if linkHoverBubble == nil {
            let bubble = LinkHoverBubble()
            bubble.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bubble)
            NSLayoutConstraint.activate([
                bubble.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor, constant: 8),
                bubble.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
                bubble.widthAnchor.constraint(
                    lessThanOrEqualTo: pageContainer.widthAnchor, multiplier: 0.62),
            ])
            linkHoverBubble = bubble
        }
        linkHoverBubble?.show(url, onPage: tab.webView?.url)
    }

    private func hideLinkHover() {
        linkHoverBubble?.hide()
    }

    // MARK: - Page context menu

    /// QR for the context menu: the right-clicked link when the menu was
    /// opened on one, otherwise the page on screen.
    private func presentMenuQRCode(link: URL?) {
        if let link {
            presentQRCode(text: link.absoluteString)
        } else {
            presentPageQRCode()
        }
    }

    /// Uses the page the user is looking at, not the tab's last committed
    /// navigation, so the code matches what is on screen.
    private func presentPageQRCode() {
        // The page this pane is hosting, which is realized by now: a pane only
        // exists for a tab the page area is showing.
        presentQRCode(text: tab.webView?.url?.absoluteString ?? "")
    }

    /// Captures the hosted page through the print pipeline and panels for a
    /// PNG destination. Same page the QR item reads, so the capture matches
    /// what is on screen.
    private func presentFullScreenCapture() {
        PageCapture.captureAndSave(webView: tab.webView, window: view.window)
    }

    // MARK: - Password autofill

    /// Opens the password manager card on this window. Behind locked Fill
    /// clicks and the Manage overflow row, so the modal is always owned by
    /// the window the menu was opened over. Prefills the manager's search
    /// with the page's base domain, so it opens on that site's credentials.
    /// The base domain (not the full host) is what matches both
    /// `example.com` and `login.example.com` entries under the vault's
    /// substring search.
    private func presentPasswordManagerForMenu() {
        guard let window = view.window else {
            SystemBeep.play()
            return
        }
        let host = PasswordAutofill.normalizeHost(url: tab.displayURL)
        let query = host.isEmpty ? "" : PasswordAutofill.baseDomain(of: host)
        BrowserCoordinator.shared.controller(for: window)?.presentPasswordManager(search: query)
    }

    /// Fills a vault credential into the page's login form. An explicit
    /// menu click always fills, even over non-empty fields.
    private func fillCredential(siteID: String, credentialID: String) {
        let store = PasswordStore.shared
        guard store.lockState == .unlocked,
              let credential = store.site(siteID)?.credentials.first(where: { $0.id == credentialID }),
              let webView = tab.webView
        else {
            SystemBeep.play()
            return
        }
        let script = PasswordFormBridge.fillLoginScript(
            username: credential.username, password: credential.password)
        Task { @MainActor in
            let raw = try? await webView.evaluateJavaScriptSafely(script)
            if (raw as? String) != "ok" {
                SystemBeep.play()
            }
        }
    }

    /// Opens the floating suggest panel anchored at the right-clicked
    /// password field. The panel hosts the shared generator (characters or
    /// diceware, with regenerate); Fill runs it into the page.
    private func openSuggestPanel(anchorView: BrowserWebView?) {
        guard let anchorView else {
            NSLog("[Passwords] suggest: anchor view gone")
            SystemBeep.play()
            return
        }
        let anchor: NSRect
        if let point = anchorView.passwordMenuPoint {
            anchor = NSRect(x: point.x - 1, y: point.y - 22, width: 2, height: 22)
        } else {
            // Keyboard-opened menu with no press and no cursor over the
            // view: center the panel on the visible page instead.
            let visible = anchorView.visibleRect
            anchor = NSRect(
                x: visible.midX - 1, y: visible.midY - 11, width: 2, height: 22)
        }
        let presenter: PasswordSuggestPresenter
        if let existing = suggestPresenter {
            presenter = existing
        } else {
            let fresh = PasswordSuggestPresenter()
            suggestPresenter = fresh
            presenter = fresh
        }
        presenter.present(
            anchorRect: anchor,
            in: anchorView,
            wordlist: PasswordGenerator.loadWordlist(),
            vaultUnlocked: PasswordStore.shared.lockState == .unlocked,
            onUse: { [weak self] password in
                self?.suggestPresenter?.dismiss()
                self?.useSuggestedPassword(password)
            }
        )
    }

    /// Fills a chosen suggested password into every visible password field
    /// (login plus its confirm twin), copies it, and saves per the plan:
    /// auto-create a site when unlocked and nothing matches, explicit
    /// update confirm when exactly one credential matches, manager when
    /// several match, nothing when locked or private.
    private func useSuggestedPassword(_ suggested: String) {
        guard !suggested.isEmpty else {
            NSLog("[Passwords] suggest: empty password chosen")
            SystemBeep.play()
            return
        }
        guard let webView = tab.webView else {
            NSLog("[Passwords] suggest: no web view")
            SystemBeep.play()
            return
        }
        let pageURL = tab.displayURL
        let host = PasswordAutofill.normalizeHost(url: pageURL)
        NSLog("[Passwords] suggest: page=%@ host=%@", pageURL.absoluteString, host)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let raw: Any?
            do {
                raw = try await webView.evaluateJavaScriptSafely(
                    PasswordFormBridge.suggestFillScript(password: suggested))
            } catch {
                NSLog("[Passwords] suggest: evaluate threw: %@", String(describing: error))
                SystemBeep.play()
                return
            }
            NSLog("[Passwords] suggest: raw=%@", String(describing: raw))
            let filled = Int((raw as? String) ?? "") ?? 0
            guard filled > 0 else {
                NSLog("[Passwords] suggest: filled=0")
                SystemBeep.play()
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(suggested, forType: .string)
            self.saveSuggestedPassword(suggested, host: host, pageURL: pageURL)
        }
    }

    /// Saves a suggested password per the locked decisions. Regular tabs
    /// only; private tabs never persist.
    private func saveSuggestedPassword(_ suggested: String, host: String, pageURL: URL) {
        guard tab.privacyMode == .regular,
              ["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""),
              !host.isEmpty
        else { return }
        let store = PasswordStore.shared
        guard store.lockState == .unlocked else { return }
        let matches = store.credentials(matchingHost: host)
        if matches.isEmpty {
            let site = store.createSite(name: host, url: pageURL.absoluteString)
            _ = store.addCredential(to: site.id, username: "", password: suggested)
            return
        }
        guard matches.count == 1, let only = matches.first else {
            // Several credentials: the menu is gone, so the manager is the
            // explicit pick surface.
            presentPasswordManagerForMenu()
            return
        }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = tr("Update saved password?", ctx: "Passwords")
        let name = only.credential.username.isEmpty ? only.siteName : only.credential.username
        alert.informativeText = tr(
            "Replace the password for {name} on {host} with the suggested one?",
            ctx: "Passwords",
            args: ["name": name, "host": host]
        )
        alert.addButton(withTitle: tr("Update", ctx: "Passwords"))
        alert.addButton(withTitle: tr("Cancel", ctx: "Dialogs"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                PasswordStore.shared.updateCredential(
                    siteID: only.siteID, only.credential.id,
                    username: only.credential.username, password: suggested)
            }
        }
    }

    // MARK: - Inline autofill and login saving

    /// Offers the vault's matching credentials under the focused login
    /// field. Unlocked with matches shows the picker; locked shows the
    /// unlock row; anything else stays quiet rather than nagging.
    private func loginFieldFocused(kind: PasswordFormBridge.FieldKind, anchor: NSRect) {
        guard kind == .password || kind == .username,
              let webView = tab.webView as? BrowserWebView,
              webView.window != nil
        else { return }
        let host = PasswordAutofill.normalizeHost(url: tab.displayURL)
        guard !host.isEmpty else { return }
        let store = PasswordStore.shared
        switch store.lockState {
        case .unlocked:
            let matches = store.credentials(matchingHost: host)
            guard !matches.isEmpty else { return }
            presentCredentialPicker(anchor: anchor, in: webView, matches: matches)
        case .locked, .unset:
            presentCredentialUnlock(anchor: anchor, in: webView)
        case .unknown:
            break
        }
    }

    private func presentCredentialPicker(
        anchor: NSRect,
        in view: NSView,
        matches: [PasswordAutofill.Match]
    ) {
        let rows = Array(matches.prefix(BrowserWebView.maxFillRows))
        let presenter: PasswordCredentialPickerPresenter
        if let existing = credentialPicker {
            presenter = existing
        } else {
            let fresh = PasswordCredentialPickerPresenter()
            credentialPicker = fresh
            presenter = fresh
        }
        presenter.present(
            anchorRect: anchor,
            in: view,
            matches: rows,
            showsManage: matches.count > BrowserWebView.maxFillRows,
            onPick: { [weak self] match in
                self?.credentialPicker?.dismiss()
                self?.fillCredential(siteID: match.siteID, credentialID: match.credential.id)
            },
            onManage: { [weak self] in
                self?.credentialPicker?.dismiss()
                self?.presentPasswordManagerForMenu()
            }
        )
    }

    private func presentCredentialUnlock(anchor: NSRect, in view: NSView) {
        let presenter: PasswordCredentialPickerPresenter
        if let existing = credentialPicker {
            presenter = existing
        } else {
            let fresh = PasswordCredentialPickerPresenter()
            credentialPicker = fresh
            presenter = fresh
        }
        presenter.presentLocked(
            anchorRect: anchor,
            in: view,
            onUnlock: { [weak self] in
                self?.credentialPicker?.dismiss()
                self?.presentPasswordManagerForMenu()
            }
        )
    }

    /// Arms the save prompt with a submitted login. Regular tabs only;
    /// the password must be non-empty (an empty submit is a failed typing,
    /// not a credential), and the vault must be unlocked — a locked vault
    /// cannot save, so there is nothing to arm.
    private func loginSubmitted(username: String, password: String) {
        guard tab.privacyMode == .regular,
              ["http", "https"].contains(tab.displayURL.scheme?.lowercased() ?? ""),
              !password.isEmpty,
              PasswordStore.shared.lockState == .unlocked
        else { return }
        pendingLogin = PendingLogin(
            formURL: tab.displayURL, username: username, password: password)
    }

    /// Retires a pending login on every committed navigation. A landing on
    /// a different address than the form is the success signal and prompts
    /// a save; a same-address commit (a re-rendered failure, a reload)
    /// clears silently. The picker anchors to the old page either way, so
    /// it goes too.
    private func noteLoginCommit(_ url: URL?) {
        credentialPicker?.dismiss()
        guard let pending = pendingLogin, let url else {
            pendingLogin = nil
            return
        }
        pendingLogin = nil
        guard !url.hasSameAddress(as: pending.formURL),
              let host = URL(string: pending.formURL.absoluteString)?.host,
              !PasswordAutofill.normalizeHost(host).isEmpty
        else { return }
        promptSaveLogin(pending, host: PasswordAutofill.normalizeHost(host))
    }

    /// Asks once whether to keep a successfully submitted login. One alert,
    /// and the Save click is the confirmation: it creates, updates, or
    /// extends the vault per `LoginSavePlan`, or opens the manager when
    /// several sites share the host and the pick needs eyes.
    private func promptSaveLogin(_ pending: PendingLogin, host: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = tr("Save password for {host}?", ctx: "Passwords", args: ["host": host])
        let name = pending.username.isEmpty ? host : pending.username
        alert.informativeText = tr(
            "Keep {name} in your passwords?",
            ctx: "Passwords",
            args: ["name": name]
        )
        alert.addButton(withTitle: tr("Save", ctx: "Passwords"))
        alert.addButton(withTitle: tr("Not Now", ctx: "Passwords"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                Self.applyLoginSave(
                    pending: pending,
                    host: host,
                    formURL: pending.formURL.absoluteString
                )
            }
        }
    }

    /// What a confirmed save does, given the vault's current matches.
    /// Static and pure over its inputs (aside from the store write) so
    /// tests pin every branch.
    enum LoginSaveAction: Equatable {
        case createSite
        case updateCredential(siteID: String, credentialID: String)
        case addCredential(siteID: String)
        case openManager
    }

    /// Picks the save action: a same-username credential gets its password
    /// replaced; a new username joins the single matching site, or starts
    /// one when nothing matches; several sites need the manager's eyes.
    static func loginSaveAction(
        matches: [PasswordAutofill.Match],
        username: String
    ) -> LoginSaveAction {
        if let same = matches.first(where: { $0.credential.username == username }) {
            return .updateCredential(siteID: same.siteID, credentialID: same.credential.id)
        }
        let siteIDs = Set(matches.map(\.siteID))
        if matches.isEmpty {
            return .createSite
        }
        if siteIDs.count == 1, let siteID = siteIDs.first {
            return .addCredential(siteID: siteID)
        }
        return .openManager
    }

    private static func applyLoginSave(pending: PendingLogin, host: String, formURL: String) {
        let store = PasswordStore.shared
        guard store.lockState == .unlocked else { return }
        switch loginSaveAction(
            matches: store.credentials(matchingHost: host),
            username: pending.username
        ) {
        case .createSite:
            let site = store.createSite(name: host, url: formURL)
            _ = store.addCredential(
                to: site.id, username: pending.username, password: pending.password)
        case .updateCredential(let siteID, let credentialID):
            store.updateCredential(
                siteID: siteID, credentialID,
                username: pending.username, password: pending.password)
        case .addCredential(let siteID):
            _ = store.addCredential(
                to: siteID, username: pending.username, password: pending.password)
        case .openManager:
            guard let window = NSApp.keyWindow,
                  let controller = BrowserCoordinator.shared.controller(for: window)
            else { return }
            controller.presentPasswordManager()
        }
    }

    private func updateBorder(activeID: UUID?, showsIndicator: Bool) {
        let isActive = showsIndicator && activeID == tab.id
        pageContainer?.layer?.borderColor = isActive
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        if isActive != pageIsActiveForTheme {
            pageIsActiveForTheme = isActive
            refreshPageThemeStyles()
        }
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
    /// pages (`w://about`, `about:blank`) have no site to name, so the title
    /// is the best available answer and the constant is the floor.
    ///
    /// Takes a plain `WKWebView` rather than the subclass because the delegate
    /// methods hand over whatever WebKit is holding.
    private func hostLabel(of webView: WKWebView) -> String {
        if let host = webView.url?.host, !host.isEmpty { return host }
        if let title = webView.title, !title.isEmpty { return title }
        return tr("This page", ctx: "Dialogs")
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
        alert.addButton(withTitle: tr("OK", ctx: "Dialogs"))
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
        alert.addButton(withTitle: tr("OK", ctx: "Dialogs"))
        alert.addButton(withTitle: tr("Cancel", ctx: "Dialogs"))
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
        alert.addButton(withTitle: tr("OK", ctx: "Dialogs"))
        alert.addButton(withTitle: tr("Cancel", ctx: "Dialogs"))
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
        panel.prompt = tr("Open", ctx: "Dialogs")

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

    // MARK: - Media capture

    /// Camera and microphone capture. Without this WebKit denies every
    /// request, so WebRTC never starts; with it the stored per-site verdict
    /// answers immediately and anything unstored waits for the user in the
    /// toolbar popup (see `resolveCapture`). Screen sharing never arrives
    /// here: the system picker answers it per share.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let kinds: [AppSettings.MediaCaptureKind]
        switch type {
        case .camera:
            kinds = [.camera]
        case .microphone:
            kinds = [.microphone]
        case .cameraAndMicrophone:
            kinds = [.camera, .microphone]
        @unknown default:
            decisionHandler(.deny)
            return
        }
        guard ["http", "https"].contains(origin.protocol.lowercased()),
              let host = URL(string: origin.protocol + "://" + origin.host)?.host?.lowercased(),
              !host.isEmpty
        else {
            decisionHandler(.deny)
            return
        }
        let stored = SettingsStore.shared.settings.mediaCapture
        // Any stored block denies the whole call: a combined request gets
        // one decision, and half a grant is not a thing.
        guard !kinds.contains(where: { stored.decision(for: host, kind: $0) == .block }) else {
            decisionHandler(.deny)
            return
        }
        let asking = kinds.filter { stored.decision(for: host, kind: $0) == .ask }
        guard !asking.isEmpty else {
            kinds.forEach { tab.tabController.noteCaptureGranted($0) }
            decisionHandler(.grant)
            return
        }
        // A re-ask supersedes whatever waited before: the old page context
        // moved on, so its handlers are answered denied and their entries
        // dropped rather than leaked. Purged first, so no dict entry can
        // ever point at an already-answered request.
        for kind in asking {
            if let old = pendingCaptureRequests[kind] {
                for member in old.kinds {
                    pendingCaptureRequests[member] = nil
                }
                preGrantedCaptureKinds.subtract(old.kinds.union(old.preGranted))
                old.kinds.forEach { tab.tabController.noteCaptureDenied($0) }
                old.resolve(.deny)
            }
        }
        let cleared = Set(kinds.filter { !asking.contains($0) })
        let request = PendingCaptureRequest(kinds: Set(asking), preGranted: cleared, host: host, answer: decisionHandler)
        for kind in asking {
            pendingCaptureRequests[kind] = request
            tab.tabController.noteCaptureRequest(kind)
        }
        preGrantedCaptureKinds.formUnion(cleared)
    }

    /// Answers a pending request from the toolbar popup: resolves the held
    /// handler and records the grant or denial on the tab. `persist` stores
    /// the verdict for the site; private tabs never persist. A combined
    /// request answers both kinds with the one verdict.
    func resolveCapture(
        kind: AppSettings.MediaCaptureKind,
        granted: Bool,
        persist: Bool
    ) {
        guard let request = pendingCaptureRequests[kind] else {
            // No waiting request (a stored verdict changed for an idle
            // kind): persist under the page when there is one.
            if persist,
               tab.privacyMode == .regular,
               let host = tab.displayURL.host?.lowercased(),
               !host.isEmpty
            {
                SettingsStore.shared.update {
                    $0.mediaCapture.setDecision(granted ? .allow : .block, for: host, kind: kind)
                }
            }
            return
        }
        if persist, tab.privacyMode == .regular {
            let host = request.host
            SettingsStore.shared.update {
                $0.mediaCapture.setDecision(granted ? .allow : .block, for: host, kind: kind)
            }
        }
        for member in request.kinds {
            pendingCaptureRequests[member] = nil
        }
        preGrantedCaptureKinds.subtract(request.kinds.union(request.preGranted))
        if granted {
            request.kinds.union(request.preGranted).forEach { tab.tabController.noteCaptureGranted($0) }
            request.resolve(.grant)
        } else {
            request.kinds.forEach { tab.tabController.noteCaptureDenied($0) }
            request.resolve(.deny)
        }
    }

    /// Origin hosts behind the currently waiting requests, by kind. The
    /// popup keys its stored-verdict segments off these rather than the top
    /// page, so an embedded frame's row shows its own verdict.
    func pendingCaptureHosts() -> [AppSettings.MediaCaptureKind: String] {
        var hosts: [AppSettings.MediaCaptureKind: String] = [:]
        for (kind, request) in pendingCaptureRequests {
            hosts[kind] = request.host
        }
        return hosts
    }

    /// Answers every waiting request denied. Navigation strands them and
    /// teardown orphans them; either way a request nobody will ever answer
    /// hangs the page's device prompt forever.
    func denyPendingCaptures() {
        var seen: [PendingCaptureRequest] = []
        for request in pendingCaptureRequests.values {
            guard !seen.contains(where: { $0 === request }) else { continue }
            seen.append(request)
            request.kinds.forEach { tab.tabController.noteCaptureDenied($0) }
            request.resolve(.deny)
        }
        pendingCaptureRequests = [:]
        preGrantedCaptureKinds = []
    }
}
