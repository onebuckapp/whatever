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

    /// Standard feed documents advertised by the current page, in document
    /// order. Empty when the page advertises none, has not finished loading,
    /// or has no committed HTTP(S) address yet.
    @Published private(set) var feedCandidates: [FeedCandidate] = []

    /// Whether feed discovery may run for the current page. Set from the
    /// toolbar binding because settings live on the main actor and this
    /// controller does not.
    private(set) var feedsEnabled = true

    /// Enables or disables feed discovery. Disabling clears any candidates
    /// immediately, so the toolbar cannot keep offering the previous page's
    /// feeds after the feature is switched off.
    func setFeedsEnabled(_ enabled: Bool) {
        feedsEnabled = enabled
        if !enabled {
            feedPage = nil
            feedCandidates = []
        }
    }

    private let audioMonitor: TabAudioMonitor
    private var observations: [NSKeyValueObservation] = []

    /// Called with the page's address whenever it changes, including for
    /// same-document navigations (`pushState`, fragments) that never produce
    /// a `didFinish` callback. The tab wires this to its history reconcile so
    /// those addresses are logged too; the reconcile is idempotent, so the
    /// overlap with `didFinish` on full loads is harmless.
    var onURLChange: ((URL) -> Void)?

    /// The page an icon lookup was started for, so a slow fetch for a page the tab
    /// has already left cannot come back and put the wrong site's icon on it.
    private var faviconPage: URL?

    /// The page a feed-discovery lookup was started for, for the same reason:
    /// discovery is asynchronous and navigation may move on before it answers.
    private var feedPage: URL?

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
        // And for its advertised feeds: candidates belong to a committed page,
        // not to the tab in the abstract.
        feedPage = nil
        feedCandidates = []
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

    /// Reloads ignoring caches, for ⇧⌘R. Same view, same history entry:
    /// only the bytes are fresh.
    func reloadFromOrigin() {
        webView?.reloadFromOrigin()
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    private func observe(_ webView: WKWebView) {
        // No canGoBack/canGoForward: a fresh view has no WebKit history;
        // Back/Forward ability comes from the tab's own URL history.
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.syncAll() },
            webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, _ in
                self?.syncAll()
                if let url = webView?.url {
                    self?.onURLChange?(url)
                }
            },
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
        updateFeedCandidates()
    }

    /// Asks for the site's icon once the tab has settled on a page.
    ///
    /// Gated on the load finishing, since a document's declared icons are only
    /// there to read after it has parsed, and on the address differing from the
    /// last one asked about, which `syncAll` runs far more often than that.
    private func updateFavicon() {
        guard !isLoading, let webView, let page = webView.url, page != faviconPage else { return }
        faviconPage = page
        FaviconLoader.shared.icon(forPageAt: page, in: webView) { [weak self] image, _ in
            guard let self, self.faviconPage == page else { return }
            self.favicon = image
        }
    }

    /// Asks the settled page for its advertised feeds.
    ///
    /// Same gating as the icon: discovery reads the parsed document, and the
    /// address check means `syncAll` running repeatedly does not rerun the
    /// script for the same page. Candidates are cleared as soon as the page
    /// changes, so the toolbar cannot show the previous page's feeds while the
    /// new page is still loading.
    private func updateFeedCandidates() {
        guard feedsEnabled, !isLoading, let webView, let page = webView.url, page != feedPage else { return }
        feedPage = page
        feedCandidates = []
        FeedDiscovery.shared.candidates(forPageAt: page, in: webView) { [weak self] candidates in
            guard let self, self.feedPage == page else { return }
            self.feedCandidates = candidates
        }
    }

    private func publishTitle() {
        title = webView?.title ?? placeholderTitle ?? "New Tab"
    }
}
