import Combine
import WebKit

/// Presentation flags a tab carries around independently of the window
/// that currently shows it.
final class BrowserTabPresentation: ObservableObject {
    @Published var isPinned = false
    /// Per-tab override of history recording.
    ///
    /// `true` records, `false` does not, and `nil` follows the app-wide setting.
    /// A tri-state rather than a plain flag so a tab opened before the user
    /// turned recording off still follows the setting instead of silently
    /// overriding it. Ignored entirely in a private tab.
    @Published var recordsHistory: Bool?
}

/// One browser tab: a `WKWebView` plus its navigation state and
/// delegates.
///
/// One page, one view: every navigation swaps in a fresh web view with a
/// fresh process pool, so a discarded page keeps no WebKit back/forward
/// cache and no processes. History is a plain in-memory array of addresses
/// owned here; Back and Forward re-access the stored address with a new
/// view. Cookies and site data survive navigation: regular tabs share the
/// persistent default store, private tabs share one isolated non-persistent
/// store per tab.
///
/// The view is optional and built on demand. A restored session opens many
/// tabs at once and only the ones on screen need a page, so each of those
/// would otherwise start loading a page the user is not looking at. Once a
/// tab has a view it keeps it: dropping views for merely-hidden tabs would
/// cost page state and scroll position every time the selection moved.
@MainActor
final class BrowserTab: NSObject {
    let id: UUID
    private(set) var webView: WKWebView?
    let tabController: BrowserTabController
    let privacyMode: BrowserPrivacyMode
    let presentation = BrowserTabPresentation()

    /// Called after a view is *swapped* so the owning window can rehost the new
    /// one.
    ///
    /// Not fired when a tab builds its first view: whoever asked for that view
    /// is the one about to host it, and telling the window to rehost in the
    /// middle of that would re-enter the very rebuild that asked for the view,
    /// tearing out a pane that is still being set up.
    var onWebViewReplaced: (() -> Void)?

    /// Whether this tab's committed pages go into history.
    ///
    /// A private tab never records, whatever the per-tab toggle or the app-wide
    /// setting says: recording a private visit is the one mistake here that
    /// cannot be walked back by turning a switch off later.
    var shouldRecordHistory: Bool {
        guard privacyMode != .privateBrowsing else { return false }
        return presentation.recordsHistory ?? SettingsStore.shared.settings.general.recordsHistory
    }

    /// When the tab was last shown. The sleeper compares this against the
    /// setting to decide whose page gets discarded; selecting the tab
    /// refreshes it. Starts at creation, so a restored window's background
    /// tabs can sleep without ever having been shown in this launch.
    private(set) var lastActiveAt = Date()

    /// Records a showing. Called by the window on every selection, including
    /// the implicit one when a tab is added or a split focuses a pane.
    func markActive() {
        lastActiveAt = Date()
    }

    /// Whether the page is allowed to see the mouse at all.
    ///
    /// Turned off for as long as a modal card covers the window. Held here rather
    /// than poked onto the current view so that a tab which builds its page *after*
    /// the card opened still comes up unable to see the pointer.
    private(set) var acceptsMouseInput = true

    /// Silences or unsilences the page. Held on the tab rather than on the view,
    /// so a cross-site navigation cannot quietly undo it.
    func toggleMute() {
        tabController.toggleMuted()
    }

    func setMuted(_ muted: Bool) {
        tabController.setMuted(muted)
    }

    private let dataStore: WKWebsiteDataStore
    private let navigationController: NavigationController

    /// Committed addresses in visit order and the current position. A value
    /// type on purpose: every mutation goes through `TabHistory`, whose rules
    /// are unit-tested, so this file only decides _when_ to record or move.
    private var tabHistory = TabHistory()

    /// A tab rebuilt from a stored session.
    struct RestoredState {
        var urls: [URL]
        var index: Int
        var title: String?
        var isPinned: Bool
        var isMuted: Bool = false
    }

    init(
        id: UUID = UUID(),
        privacyMode: BrowserPrivacyMode = .regular,
        history: HistoryRecording,
        initialURL: URL? = nil,
        restored: RestoredState? = nil
    ) {
        self.id = id
        self.privacyMode = privacyMode

        let dataStore: WKWebsiteDataStore = privacyMode == .privateBrowsing
            ? .nonPersistent()
            : .default()
        self.dataStore = dataStore

        let tab = BrowserTabController(
            id: id,
            webView: nil,
            privacyMode: privacyMode,
            isMuted: restored?.isMuted ?? false
        )
        self.tabController = tab

        let navigation = NavigationController(history: history)
        self.navigationController = navigation

        super.init()
        navigation.owner = self

        if let restored {
            self.tabHistory = TabHistory(urls: restored.urls,
                                         index: restored.index)
            presentation.isPinned = restored.isPinned
            // Shown until the page reports a title of its own, so a restored tab
            // bar reads correctly before the first load finishes.
            tab.setPlaceholderTitle(restored.title)
        } else {
            self.tabHistory = TabHistory(
                urls: [initialURL ?? BrowserConstants.homePageURL], index: 0)
        }
        // After super.init: capturing self earlier is a compile error.
        // Sees every address change, including same-document ones `didFinish`
        // never reports. Hops to the main actor: WebKit delivers these
        // observations on the main thread, and the hop keeps that an
        // assumption rather than a crash if it ever changes.
        tab.onURLChange = { [weak self] url in
            Task { @MainActor in
                self?.noteCommitted(url: url)
            }
        }
        updateHistoryNavigation()
    }

    /// The address this tab is on, whether or not it has a view yet.
    ///
    /// This is the tab's own history rather than the loaded page, so it answers
    /// the same before a view exists. A caller wanting what is actually on
    /// screen wants `webView?.url` instead.
    var currentURL: URL {
        tabHistory.currentURL ?? BrowserConstants.homePageURL
    }

    /// What the page area should show this tab as.
    ///
    /// Prefers the live page so a URL that redirects, or a `w://` homepage
    /// with no address bar entry, reports what the user sees.
    var displayURL: URL {
        webView?.url ?? currentURL
    }

    /// Takes the page out of, or back into, mouse interaction.
    ///
    /// The modal shield already stops presses from landing on the page, but it
    /// cannot stop the page *noticing* the pointer pass over it: WebKit's own
    /// hover tracking keeps running underneath, which is what lights up links and
    /// leaves hover styling behind while a card is up. Removing the views from
    /// interaction is what actually ends that.
    func setAcceptsMouseInput(_ accepts: Bool) {
        guard acceptsMouseInput != accepts else { return }
        acceptsMouseInput = accepts
        (webView as? BrowserWebView)?.takesMouseInput = accepts
    }


    /// Builds the view if it does not exist, and loads the current address into
    /// it. Returns the view either way.
    ///
    /// Call this wherever something genuinely needs a page: hosting it in a pane,
    /// focusing it, handing it to WebKit for a `window.open`. Everything else
    /// should read `currentURL` and leave the tab unrealized.
    @discardableResult
    func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let fresh = WebViewFactory.makeWebView(mode: privacyMode, dataStore: dataStore)
        fresh.navigationDelegate = navigationController
        fresh.takesMouseInput = acceptsMouseInput
        webView = fresh
        tabController.retarget(to: fresh)
        tabController.load(currentURL)
        return fresh
    }

    /// Drops the view, keeping the history. Frees the page's processes.
    ///
    /// The dying view is navigated to blank first: releasing it lets the
    /// process die whenever WebKit gets around to it, and a closed audible
    /// tab keeps playing for a second or two on the way out. Destroying the
    /// document stops every media element and audio context at commit,
    /// while the history (which is what waking or reopening reads) is
    /// untouched — the delegate is already gone, so the blank commits
    /// silently.
    func discardWebView() {
        guard let old = webView else { return }
        // The bar keeps showing the page's title while the tab has no view:
        // the placeholder stands in until the rebuilt page reports its own.
        tabController.setPlaceholderTitle(tabController.title)
        old.stopLoading()
        if old.url?.absoluteString != "about:blank" {
            old.load(URLRequest(url: URL(string: "about:blank")!))
        }
        old.navigationDelegate = nil
        old.removeFromSuperview()
        webView = nil
        tabController.detachFromWebView()
    }

    /// Puts the current address back after the page's process was killed.
    ///
    /// Loads in place rather than going through `navigate(to:)`, which would
    /// append a second copy of the address to the history: the user never asked
    /// to go anywhere, the page simply died where it was. The view is intact even
    /// though its document is not, so this is a plain load onto the same page.
    func reloadAfterContentProcessTermination() {
        guard let webView else { return }
        let url = webView.url ?? currentURL
        webView.load(URLRequest(url: url))
    }

    /// Navigates to a new address: records it, dropping any forward entries.
    ///
    /// Stays in the current page when the address is on the same site, and only
    /// replaces the page when it is not. See `load(_:from:)`.
    func navigate(to url: URL) {
        let previous = currentURL
        tabHistory.navigate(to: url)
        load(url, from: previous)
        updateHistoryNavigation()
        BrowserCoordinator.shared.sessionDidChange()
    }

    /// Logs an address the page committed to without going through
    /// `navigate(to:)` — scripted, form, and redirect navigations, which WebKit
    /// performs in place. Without this the tab's history disagrees with what is
    /// on screen and Back jumps over the missing entry.
    ///
    /// No-op when the committed address matches the current one, so reloads
    /// and back/forward loads (which move the index first) never duplicate.
    /// Deliberately unconditional: every new address access is logged, and
    /// nothing here collapses repeats.
    func noteCommitted(url: URL) {
        guard tabHistory.noteCommitted(url) else { return }
        updateHistoryNavigation()
        BrowserCoordinator.shared.sessionDidChange()
    }

    /// Re-accesses the previous address with a new view. Nothing is
    /// restored from cache; the address is loaded anew.
    func goBack() {
        // Captured before the move: `currentURL` already answers with the new
        // one by the time `load` runs, and `load` needs the old one.
        let previous = currentURL
        guard let target = tabHistory.moveBack() else {
            SystemBeep.play()
            return
        }
        load(target, from: previous)
        updateHistoryNavigation()
        BrowserCoordinator.shared.sessionDidChange()
    }

    /// Re-accesses the next address with a new view.
    func goForward() {
        // Captured before the move, for the same reason as in `goBack`.
        let previous = currentURL
        guard let target = tabHistory.moveForward() else {
            SystemBeep.play()
            return
        }
        load(target, from: previous)
        updateHistoryNavigation()
        BrowserCoordinator.shared.sessionDidChange()
    }

    /// The tab's own history, for a session snapshot.
    ///
    /// Only meaningful for a regular tab: private tabs are filtered out before a
    /// snapshot is built.
    func historySnapshot() -> (urls: [URL], index: Int) {
        (tabHistory.urls, tabHistory.index)
    }

    /// Shows `url`, keeping the current page when the two addresses are on the
    /// same site.
    ///
    /// Within a site there is nothing to gain from a new page: it costs a WebKit
    /// process spawn, loses the back/forward cache, and shows as a blank frame
    /// while the new view paints. So the address goes into the view that is
    /// already there, which is also what forms and scripted navigations have
    /// always done. Crossing to a different site replaces the page, so unrelated
    /// sites keep separate processes.
    ///
    /// `previous` has to be the address the tab was on, captured before the
    /// caller moved `historyIndex`, since `currentURL` already answers with the
    /// new one by then.
    private func load(_ url: URL, from previous: URL) {
        guard let webView, SiteIdentity.isSameSite(previous, url) else {
            replaceWebView()
            return
        }
        webView.load(URLRequest(url: url))
    }

    private func replaceWebView() {
        // A tab with no view yet is just gaining its first one, which is not a
        // swap and has nothing for the window to rehost.
        guard webView != nil else {
            ensureWebView()
            return
        }
        // Dropping before building rather than swapping in place, so
        // `ensureWebView` cannot hand back the view that is on its way out.
        discardWebView()
        ensureWebView()
        onWebViewReplaced?()
    }

    private func updateHistoryNavigation() {
        tabController.setHistoryNavigation(
            canGoBack: tabHistory.canGoBack,
            canGoForward: tabHistory.canGoForward
        )
    }
}

extension BrowserTab: NSPasteboardWriting {
    /// Only the identifier is published. The drag destination resolves
    /// it back to this same tab so the web view moves rather than the
    /// page being reloaded somewhere else.
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [TabDragPayload.type]
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        []
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == TabDragPayload.type else { return nil }
        return id.uuidString
    }
}