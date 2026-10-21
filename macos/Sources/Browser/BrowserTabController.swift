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
import PDFKit
import Security
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

    @Published private(set) var title: String = tr("New Tab", ctx: "Tabs")
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

    /// The current page's `<video>` elements, in document order, pushed by
    /// the detector script whenever the set changes. Empty when the page
    /// has no eligible video or its view is gone.
    @Published private(set) var videoCandidates: [VideoCandidate] = []

    /// Whether the page currently holds a PiP window. Pushed by the
    /// detector's PiP events, so closing the window from the window itself
    /// flips the toolbar button back without a poll.
    @Published private(set) var isPipActive = false

    /// Whether our in-page fallback box currently owns a video. Pushed by
    /// the detector with the same report, so its close button flips the
    /// toolbar back the same way a system window close does.
    @Published private(set) var isFloating = false

    /// Consecutive failed native entries. Two in a row floats the video
    /// instead of failing silently a third time; any success resets.
    private(set) var consecutivePipFailures = 0

    /// Whether the toolbar offers Picture in Picture: exactly when a video
    /// is currently playing.
    var hasPipVideo: Bool {
        VideoDetector.pickBestVideo(from: videoCandidates) != nil
    }

    /// What the tab's native PDF viewer is showing. `.none` means the tab
    /// is a web page; anything else means the pane hosts the viewer instead
    /// of a web view, so WebKit's built-in PDF toolbar never appears.
    @Published private(set) var pdfState = PDFViewerState.none

    /// Whether the pane should host the PDF viewer rather than a web view.
    var isPDF: Bool {
        pdfState != .none
    }

    /// Marks a PDF fetch in flight. The viewer shows its spinner.
    func showPDFLoading(url: URL) {
        pdfState = .loading(url)
    }

    /// Shows fetched bytes. A viewer showing an older document for the same
    /// address keeps it until a newer one lands: generations are ordered by
    /// the tab, so this is always the latest.
    func showPDF(document: PDFDocument, data: Data, url: URL, filename: String) {
        pdfState = .ready(document: document, data: data, url: url, filename: filename)
    }

    /// Shows a fetch failure with a retry affordance. The source address is
    /// kept so retry knows where to go.
    func showPDFError(url: URL, message: String) {
        pdfState = .failed(url: url, message: message)
    }

    /// Drops the viewer state, e.g. when navigating back to a web page.
    func clearPDF() {
        pdfState = .none
    }

    /// What the page is doing with the camera and microphone.
    /// Published from the hosting pane's permission delegate rather than
    /// read from the view, so the toolbar can follow capture without
    /// knowing whether a page exists. Cleared like every other page-owned
    /// state when the page goes away; grants are assumed live until then,
    /// which is the honest limit of the public API (see `MediaCaptureState`).
    @Published private(set) var captureState = MediaCaptureState()
    /// Host the capture state above belongs to. A navigation to a new host
    /// drops it; same-host walks keep their grants.
    private var captureHost: String?
    /// The page's TLS certificate, snapshotted from the server-trust
    /// challenge during the handshake — the only moment WebKit hands over
    /// the trust object. Read by the site-information card; cleared with
    /// the rest of the page-owned state.
    @Published private(set) var siteCertificate: SiteCertificateInfo?

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
        // The new page has reported nothing yet: the old page's videos
        // would otherwise offer PiP into a document that is gone.
        videoCandidates = []
        isPipActive = false
        isFloating = false
        consecutivePipFailures = 0
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
        // And for its captures: a view that is gone holds no microphone.
        captureHost = nil
        captureState = MediaCaptureState()
        // And for its videos: candidates belong to the reported document,
        // and a view that is gone reports nothing.
        videoCandidates = []
        isPipActive = false
        isFloating = false
        consecutivePipFailures = 0
        // And for its certificate: the chain belonged to that page's handshake.
        siteCertificate = nil
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

    /// Notes a capture request awaiting the user's verdict.
    func noteCaptureRequest(_ kind: AppSettings.MediaCaptureKind) {
        captureState.noteRequest(kind)
    }

    /// Notes a granted request: answered, and assumed live.
    func noteCaptureGranted(_ kind: AppSettings.MediaCaptureKind) {
        captureState.noteGranted(kind)
    }

    /// Notes a denied request: answered, and gone.
    func noteCaptureDenied(_ kind: AppSettings.MediaCaptureKind) {
        captureState.noteDenied(kind)
    }

    /// Replaces the page's video report. Pushed by the detector script
    /// whenever the set changes, so play and pause move the toolbar button
    /// without polling.
    func noteVideoReport(_ report: VideoReport) {
        videoCandidates = report.candidates
        isPipActive = report.pipActive
        isFloating = report.floating
    }

    /// Moves the currently playing video into a system PiP window.
    ///
    /// Asks the page's own element, so DRM and adaptive streams work where
    /// an extracted URL would not. Each frame enters its own best video
    /// and the traversal takes the first win, so a re-rendered page and an
    /// embedded player are both covered without trusting a stale index.
    ///
    /// Answers the page's verdict (`"ok"`, `"pending"`, a reason with
    /// element facts, …) so the caller can say why a dead button died
    /// instead of swallowing it. Success resets the failure count; any
    /// other answer raises it toward the floating fallback.
    func enterPictureInPicture() async -> String {
        guard let webView, hasPipVideo else { return "idle" }
        do {
            let answer = try await webView.evaluateJavaScriptSafely(
                VideoDetector.enterPictureInPictureSource()
            )
            let verdict = (answer as? String) ?? "failed"
            if verdict == "ok" || verdict == "pending" {
                consecutivePipFailures = 0
            } else {
                consecutivePipFailures += 1
                NSLog("[PiP] enter failed: %@", verdict)
            }
            return verdict
        } catch {
            consecutivePipFailures += 1
            NSLog("[PiP] enter threw: %@", String(describing: error))
            return "failed"
        }
    }

    /// Whether the next failed entry should float instead of failing
    /// again: two strikes, and the button must do *something*. Never
    /// while already floating.
    var shouldFloatAfterFailure: Bool {
        consecutivePipFailures >= 2 && !isFloating
    }

    /// Moves the best video into the page's own floating box (see
    /// `floatPictureInPictureSource`). Success resets the failure count,
    /// so a recovered page goes back to trying the system first.
    func floatPictureInPicture() async -> String {
        guard let webView, hasPipVideo else { return "idle" }
        do {
            let answer = try await webView.evaluateJavaScriptSafely(
                VideoDetector.floatPictureInPictureSource()
            )
            let verdict = (answer as? String) ?? "failed"
            if verdict == "ok" {
                consecutivePipFailures = 0
            } else {
                NSLog("[PiP] float failed: %@", verdict)
            }
            return verdict
        } catch {
            NSLog("[PiP] float threw: %@", String(describing: error))
            return "failed"
        }
    }

    /// Returns the floated video to its page slot. Closing the fallback
    /// is a deliberate act, so the failure count resets with it: the next
    /// press tries the system again rather than re-floating blindly.
    func unfloatPictureInPicture() async {
        consecutivePipFailures = 0
        guard let webView, isFloating else { return }
        _ = try? await webView.evaluateJavaScriptSafely(
            VideoDetector.unfloatPictureInPictureSource
        )
    }

    /// Closes the page's PiP window, however it was opened. Answers from
    /// the page, so a window the user already closed from the window
    /// itself settles as idle rather than an error.
    func exitPictureInPicture() async {
        guard let webView, isPipActive else { return }
        _ = try? await webView.evaluateJavaScriptSafely(
            VideoDetector.exitPictureInPictureSource
        )
    }

    /// Snapshots the server's certificate for the site-information card.
    /// Called from the navigation delegate's authentication challenge,
    /// during the handshake that serves the chain.
    func noteServerTrust(_ trust: SecTrust, host: String) {
        siteCertificate = SiteCertificateInfo.make(trust: trust, host: host)
    }

    private func syncAll() {
        if let loaded = webView?.title {
            placeholderTitle = nil
            title = loaded
        } else {
            publishTitle()
        }
        url = webView?.url
        carryCaptureState(to: url?.host?.lowercased())
        isLoading = webView?.isLoading ?? false
        estimatedProgress = webView?.estimatedProgress ?? 0
        updateFavicon()
        updateFeedCandidates()
    }

    /// Carries capture grants across same-host navigations and drops them
    /// on host changes. Pending requests never survive the move: their
    /// page is gone, and the pane answers them denied (see `carried`).
    /// The certificate drops with a real host change too — but only then:
    /// the challenge lands before the new address commits, so dropping on
    /// any mismatch would discard a certificate its own page has not
    /// reached yet.
    private func carryCaptureState(to host: String?) {
        let moved = captureHost != host
        let carried = MediaCaptureState.carried(from: captureHost, to: host, state: captureState)
        captureHost = host
        captureState = carried
        if moved, siteCertificate?.host != host {
            siteCertificate = nil
        }
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
        title = webView?.title ?? placeholderTitle ?? tr("New Tab", ctx: "Tabs")
    }
}
