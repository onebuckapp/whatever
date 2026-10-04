import Combine
import WebKit

/// Observable wrapper around a tab's `WKWebView`. Publishes navigation
/// state via KVO so the toolbar, address field and tab bar follow the
/// page.
///
/// The web view is replaced on every page change (see `BrowserTab`),
/// so this observes whichever view is current. Back/Forward ability
/// comes from the tab's own URL history, not the web view: Back always
/// re-accesses the address with a fresh view.
///
/// A tab being unrealized has no web view to observe, and the observations are
/// torn down and the published state cleared at that point. `canGoBack` and
/// `canGoForward` deliberately survive, because they come from the tab's history
/// and stay true across losing the page.
final class BrowserTabController: ObservableObject {
    let id: UUID
    private(set) var webView: WKWebView?
    let privacyMode: BrowserPrivacyMode

    @Published private(set) var title: String = "New Tab"
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var estimatedProgress = 0.0

    /// Whether the page is making sound, and whether the user has silenced it.
    ///
    /// Published from the tab's `TabAudioMonitor` rather than read from the view,
    /// so the tab bar can follow audio without knowing whether a page exists.
    /// `isMuted` deliberately survives losing the view: the view is replaced on
    /// every cross-site navigation, and a tab the user silenced should stay
    /// silenced. `isProducingAudio` does not, because a page that has not loaded
    /// cannot be making sound.
    @Published private(set) var isProducingAudio = false
    @Published private(set) var isMuted: Bool

    /// The page's own icon, or `nil` to leave the caller on its default globe.
    @Published private(set) var favicon: NSImage?

    private let audioMonitor: TabAudioMonitor
    private var observations: [NSKeyValueObservation] = []

    /// The page an icon lookup was started for, so a slow fetch for a page the tab
    /// has already left cannot come back and put the wrong site's icon on it.
    private var faviconPage: URL?

    /// Title to show until the page reports one of its own.
    ///
    /// A restored tab knows its title from the session document, and showing
    /// "New Tab" until the first load finishes reads as a failed restore. Dropped
    /// as soon as a real title arrives.
    private var placeholderTitle: String?

    init(
        id: UUID = UUID(),
        webView: WKWebView?,
        privacyMode: BrowserPrivacyMode = .regular,
        isMuted: Bool = false
    ) {
        self.id = id
        self.webView = webView
        self.privacyMode = privacyMode
        self.isMuted = isMuted
        let monitor = TabAudioMonitor(isMuted: isMuted)
        self.audioMonitor = monitor
        monitor.onChange = { [weak self] isProducingAudio, isMuted in
            self?.isProducingAudio = isProducingAudio
            self?.isMuted = isMuted
        }
        if let webView {
            observe(webView)
            syncAll()
        }
    }

    /// Sets the title shown until the page reports one of its own.
    func setPlaceholderTitle(_ title: String?) {
        placeholderTitle = title
        publishTitle()
    }

    var state: BrowserTabState {
        BrowserTabState(
            id: id,
            title: title,
            url: url,
            isLoading: isLoading,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            estimatedProgress: estimatedProgress
        )
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    /// Points this controller at a replacement view, re-observing it and
    /// publishing its current state. Called by `BrowserTab` when it
    /// swaps views for a new page.
    func retarget(to newWebView: WKWebView) {
        webView = newWebView
        observe(newWebView)
        syncAll()
    }

    /// Publishes cleared state after the tab drops its view, so nothing keeps
    /// showing the page that view was showing.
    func detachFromWebView() {
        observations = []
        webView = nil
        isLoading = false
        estimatedProgress = 0
        url = nil
        // Same reasoning for the icon: the page that owned it is gone.
        faviconPage = nil
        favicon = nil
        // Clears the audio flag and drops the poll. The mute stays: it belongs to
        // the tab, and is re-applied to whichever view comes next.
        audioMonitor.detach()
        publishTitle()
    }

    /// Silences or unsilences the tab's page.
    func setMuted(_ muted: Bool) {
        audioMonitor.setMuted(muted)
    }

    func toggleMuted() {
        audioMonitor.setMuted(!isMuted)
    }

    /// Back/Forward ability from the tab's own history. Called by
    /// `BrowserTab` whenever its history index moves.
    func setHistoryNavigation(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    func reload() {
        webView?.reload()
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    private func observe(_ webView: WKWebView) {
        // No canGoBack/canGoForward: a fresh view has no WebKit history;
        // Back/Forward ability comes from the tab's own URL history.
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.syncAll() },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.syncAll() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.syncAll() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.syncAll() },
        ]
        // Watched from here rather than from `retarget` alone, so a tab that
        // arrives with a view already built is watched too.
        audioMonitor.attach(to: webView)
    }

    private func syncAll() {
        if let loaded = webView?.title {
            placeholderTitle = nil
            title = loaded
        } else {
            publishTitle()
        }
        url = webView?.url
        isLoading = webView?.isLoading ?? false
        estimatedProgress = webView?.estimatedProgress ?? 0
        updateFavicon()
    }

    /// Asks for the site's icon once the tab has settled on a page.
    ///
    /// Gated on the load finishing, since a document's declared icons are only
    /// there to read after it has parsed, and on the address differing from the
    /// last one asked about, which `syncAll` runs far more often than that.
    private func updateFavicon() {
        guard !isLoading, let webView, let page = webView.url, page != faviconPage else { return }
        faviconPage = page
        FaviconLoader.shared.icon(forPageAt: page, in: webView) { [weak self] image in
            guard let self, self.faviconPage == page else { return }
            self.favicon = image
        }
    }

    private func publishTitle() {
        title = webView?.title ?? placeholderTitle ?? "New Tab"
    }
}
