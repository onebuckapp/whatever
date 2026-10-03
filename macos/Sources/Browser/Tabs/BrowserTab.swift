import Combine
import WebKit

/// Presentation flags a tab carries around independently of the window
/// that currently shows it.
final class BrowserTabPresentation: ObservableObject {
    @Published var isPinned = false
}

/// One browser tab: a `WKWebView` plus its navigation state and
/// delegates.
///
/// One page, one view: every navigation swaps in a fresh web view with
/// a fresh process pool, so a discarded page keeps no WebKit
/// back/forward cache and no processes. History is a plain in-memory
/// array of addresses owned here; Back and Forward re-access the stored
/// address with a new view. Cookies and site data survive navigation:
/// regular tabs share the persistent default store, private tabs share
/// one isolated non-persistent store per tab.
final class BrowserTab: NSObject {
    let id: UUID
    private(set) var webView: WKWebView
    let tabController: BrowserTabController
    let privacyMode: BrowserPrivacyMode
    let presentation = BrowserTabPresentation()

    /// Called after the view is swapped so the owning window can rehost
    /// the new view.
    var onWebViewReplaced: (() -> Void)?

    private let dataStore: WKWebsiteDataStore
    private let navigationController: NavigationController

    /// Committed addresses in visit order; `historyIndex` is the current
    /// page.
    private var history: [URL] = []
    private var historyIndex = -1

    init(
        id: UUID = UUID(),
        privacyMode: BrowserPrivacyMode = .regular,
        history: HistoryRecording,
        initialURL: URL? = nil
    ) {
        self.id = id
        self.privacyMode = privacyMode

        let dataStore: WKWebsiteDataStore = privacyMode == .privateBrowsing
            ? .nonPersistent()
            : .default()
        self.dataStore = dataStore

        let webView = WebViewFactory.makeWebView(mode: privacyMode, dataStore: dataStore)
        self.webView = webView

        let tab = BrowserTabController(id: id, webView: webView, privacyMode: privacyMode)
        self.tabController = tab

        let navigation = NavigationController(history: history)
        self.navigationController = navigation
        webView.navigationDelegate = navigation

        super.init()
        navigation.owner = self

        let start = initialURL ?? BrowserConstants.homePageURL
        self.history = [start]
        self.historyIndex = 0
        updateHistoryNavigation()
        tab.load(start)
    }

    /// Navigates to a new address: records it (dropping any forward
    /// entries) and loads it in a fresh view. The previous page is
    /// discarded with its processes.
    func navigate(to url: URL) {
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        history.append(url)
        historyIndex = history.count - 1
        loadFresh(url)
    }

    /// Re-accesses the previous address with a new view. Nothing is
    /// restored from cache; the address is loaded anew.
    func goBack() {
        guard historyIndex > 0 else {
            SystemBeep.play()
            return
        }
        historyIndex -= 1
        loadFresh(history[historyIndex])
    }

    /// Re-accesses the next address with a new view.
    func goForward() {
        guard historyIndex >= 0, historyIndex < history.count - 1 else {
            SystemBeep.play()
            return
        }
        historyIndex += 1
        loadFresh(history[historyIndex])
    }

    private func loadFresh(_ url: URL) {
        replaceWebView()
        updateHistoryNavigation()
        tabController.load(url)
    }

    private func replaceWebView() {
        let old = webView
        old.stopLoading()
        old.navigationDelegate = nil
        let fresh = WebViewFactory.makeWebView(mode: privacyMode, dataStore: dataStore)
        fresh.navigationDelegate = navigationController
        webView = fresh
        tabController.retarget(to: fresh)
        old.removeFromSuperview()
        onWebViewReplaced?()
    }

    private func updateHistoryNavigation() {
        tabController.setHistoryNavigation(
            canGoBack: historyIndex > 0,
            canGoForward: historyIndex >= 0 && historyIndex < history.count - 1
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
