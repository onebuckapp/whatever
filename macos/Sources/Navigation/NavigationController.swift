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
@preconcurrency import WebKit

/// Owns `WKNavigationDelegate` for one tab: window title updates,
/// navigation policy, and history recording.
///
/// Link clicks on the main frame never navigate the current view: the
/// tab loads the address in a fresh view instead, so the discarded page
/// keeps no back/forward cache and no processes. Set `owner` after the
/// tab finishes init; without an owner links fall back to in-place
/// navigation.
final class NavigationController: NSObject {
    weak var owner: BrowserTab?
    private let history: HistoryRecording

    init(history: HistoryRecording) {
        self.history = history
    }
}

extension NavigationController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        webView.window?.title = tr("Loading…", ctx: "Window")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.window?.title = webView.title ?? tr("New Tab", ctx: "Window")
        // A page that finishes loading behind an open card installs fresh mouse
        // tracking areas, which would hand the pointer and hover straight back to
        // it. Take them off again.
        (webView as? BrowserWebView)?.reassertMouseInputSuppression()
        // The in-memory homepage is not a visit worth remembering, and neither is
        // anything in a private tab or a tab with recording turned off. The tab
        // owns that decision because it is the thing that knows its privacy mode.
        guard let owner, let url = webView.url, !url.isAddresslessPage else {
            return
        }
        if owner.shouldRecordHistory {
            history.record(url: url, title: webView.title)
        }
        // The tab's own history logs every commit regardless of recording
        // mode: back/forward has to work in private tabs too.
        owner.noteCommitted(url: url)
        // A commit that did not grow the back list and saw no redirect
        // replaced the current item (`location.replace`) instead of
        // pushing: fold it into the previous entry so Back skips the
        // replaced chain, Chrome-parity. A landing after redirects takes
        // the normal path even though redirects do not grow the list
        // either — the one-shot flag tells them apart — and so does the
        // landing of a load the app itself started (address bar, routed
        // link, Back/Forward), which WebKit may not have filed yet at
        // finish time.
        let sawRedirect = owner.consumeServerRedirectFlag()
        let appInitiated = owner.consumeAppInitiatedFlag()
        if let pending = owner.pendingBackListCount,
           webView.backForwardList.backList.count <= pending,
           !sawRedirect,
           !appInitiated
        {
            owner.foldReplaceLanding(url: url)
        }
        // Retires the finished page from the unfinished tracker, and
        // disarms a form-skip when the POST itself rendered instead of
        // redirecting: no thanks-commit is coming.
        owner.noteLoadFinished(url: url)
    }

    /// Opens a new tab for `url`, in the window `webView` is showing.
    ///
    /// A free function because it needs the window the page is on, which the
    /// navigation delegate has and the tab does not: the tab knows nothing about
    /// which window is hosting it. The opener's privacy mode is inherited, so a
    /// private tab can only ever open another private one.
    @MainActor
    private func openPopup(_ url: URL, from webView: WKWebView, owner: BrowserTab) {
        let controller = BrowserCoordinator.shared.controller(for: webView.window)
            ?? BrowserCoordinator.shared.keyController
        // Focus follows here rather than being deferred: the address bar is
        // pre-filled with the popup's own address, so a user who then types
        // replaces that rather than adding to it.
        _ = BrowserCoordinator.shared.newTab(
            url: url,
            privacyMode: owner.privacyMode,
            in: controller
        )
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.window?.title = tr("Failed to Load", ctx: "Window")
    }

    /// A server redirect replaced its source without committing it. The
    /// callback carries no address, but redirects complete in order, so the
    /// tab drops its oldest unfinished navigation — the hop — whenever this
    /// arrives relative to commit observations.
    func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        owner?.noteServerRedirect()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        webView.window?.title = tr("Failed to Load", ctx: "Window")
    }

    /// The page's WebContent process died under it.
    ///
    /// The view survives this but the document is gone, and WebKit does not
    /// recover on its own: what is left is a permanently blank frame with no way
    /// back short of the user noticing and reloading by hand. Re-navigating to
    /// the address the view was on is the whole recovery.
    ///
    /// Asked of the tab rather than answered here, because the tab's own history
    /// is what knows the address that was on screen.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard owner != nil else { return }
        webView.window?.title = tr("Reloading…", ctx: "Window")
        owner?.reloadAfterContentProcessTermination()
    }

    /// Server trust: snapshots the served chain for the site-information
    /// card, then gets out of TLS's way. Default handling performs the
    /// real validation; answering anything else here would either weaken
    /// it or break every https page, and neither is this method's job.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust
        {
            owner?.tabController.noteServerTrust(trust, host: challenge.protectionSpace.host.lowercased())
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Anything WebKit cannot render — attachments, archives, installers —
        // becomes a download instead of a blank viewer. An explicitly
        // attached response downloads even when its MIME type is renderable:
        // that header is the server saying "save this", which is how sites
        // like Unsplash force-save otherwise viewable images. Renderable
        // responses flow through untouched, including file:// listings the
        // file browser already handles.
        guard !navigationResponse.canShowMIMEType
            || Self.servesAttachment(navigationResponse.response)
        else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.download)
    }

    /// Whether the response carries `Content-Disposition: attachment`: the
    /// server's explicit save-this-file instruction, independent of MIME type.
    /// Static and nonisolated so tests can prove the rule without a web view.
    static nonisolated func servesAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased()
            .contains("attachment") == true
    }

    /// Continues a response the policy turned into a download: WebKit hands
    /// over the transfer, and the app takes ownership from here.
    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        // A response without a URL has nothing to attribute the file to, so
        // it is dropped rather than recorded under a placeholder address.
        guard let source = navigationResponse.response.url else { return }
        // Recorded regardless of privacy mode: the file itself lands on
        // disk by user action either way, so the row is a pointer to real
        // user data, not a browsing trace.
        let operation = WebDownload(
            download: download,
            sourceURL: source,
            suggestedFilename: navigationResponse.response.suggestedFilename,
            bytesExpected: navigationResponse.response.expectedContentLength
        )
        Task { @MainActor in
            DownloadsCenter.shared.adopt(operation)
        }
    }

    /// Continues a download WebKit started on its own — "Download Image" and
    /// "Download Linked File" from the context menu never consult the action
    /// policy, so without this they die silently. There is no response to
    /// read, so the filename comes from the URL and the size stays unknown
    /// until the destination decision reports it.
    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        guard let source = navigationAction.request.url else { return }
        let operation = WebDownload(
            download: download,
            sourceURL: source,
            suggestedFilename: nil,
            bytesExpected: -1
        )
        Task { @MainActor in
            DownloadsCenter.shared.adopt(operation)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let policy = NavigationPolicy.decision(for: navigationAction.request)
        guard policy == .allow else {
            // External scheme: already handed to the OS by the policy.
            decisionHandler(policy)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // A main-frame POST is a submission, not a page: its address never
        // records, and the form it leaves may leave with the redirect
        // answer. Subframe POSTs need no marking — their commits never reach
        // the tab's history. See `BrowserTab.notePOSTRequest`.
        if navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.httpMethod?.uppercased() == "POST",
           let owner {
            owner.notePOSTRequest(url: url)
        }
        // Records the back-list depth the navigation starts from: a commit
        // that does not grow it replaced the current item
        // (`location.replace`). Main frame and frameless actions only — a
        // subframe action interleaved in a redirect window must neither move
        // the depth nor clear the redirect veto below.
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == true,
           let owner
        {
            owner.noteNavigationStarted(backListCount: webView.backForwardList.backList.count)
        }
        // Reloads and system back/forward loads are app-level moves, never
        // replaces: their landings keep their entries even though neither
        // grows the back list. Armed here because they never pass through
        // the tab's own `load`.
        if navigationAction.navigationType == .reload
            || navigationAction.navigationType == .backForward,
            let owner
        {
            owner.noteAppInitiatedNavigation()
        }
        // A link with no target frame asked for a new window: `target="_blank"`,
        // a scripted `window.open`, or an explicit new-tab click (⌘/⇧ held).
        // Only the last two open tabs — a bare `_blank` left-click, the shape
        // search engines use for result links, navigates the current tab so
        // Back keeps working there. See `NavigationPolicy.opensNewTab`.
        if navigationAction.targetFrame == nil,
           navigationAction.navigationType != .backForward,
           let owner
        {
            if NavigationPolicy.opensNewTab(
                navigationType: navigationAction.navigationType,
                modifierFlags: navigationAction.modifierFlags,
                targetFrameIsNil: true
            ) {
                guard NavigationPolicy.canLoadInPage(navigationAction.request) else {
                    // A scheme the web view cannot draw, such as mailto: or tel:.
                    // The tab is never opened; the link goes to the app that handles
                    // it, which is what a click on it means anywhere else.
                    NavigationPolicy.handOffToSystem(url)
                    decisionHandler(.cancel)
                    return
                }
                // A real tab rather than answering `createWebViewWith`: WebKit
                // performs the navigation it delegates only after that call
                // returns, by which point the new tab is already selected and
                // loading its own address, so the popup would land on the
                // homepage rather than the page that opened it.
                openPopup(url, from: webView, owner: owner)
                decisionHandler(.cancel)
                return
            }
            // Same-tab below: the framed branches require a main frame, which a
            // frameless action never has, so the schemes route here instead.
            if navigationAction.navigationType == .linkActivated,
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "w", "whtvr"].contains(scheme)
            {
                owner.navigate(to: url)
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               url.scheme?.lowercased() == "file"
            {
                let controller = BrowserCoordinator.shared.controller(for: webView.window)
                    ?? BrowserCoordinator.shared.keyController
                controller?.openFileLink(url, for: owner)
                decisionHandler(.cancel)
                return
            }
        }
        // Same-tab link: load it in a fresh view through the tab, which
        // records it in the tab's own history. Forms, reloads, and scripted
        // navigations stay in place.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           let scheme = url.scheme?.lowercased(),
            ["http", "https", "w", "whtvr"].contains(scheme),
           let owner {
            owner.navigate(to: url)
            decisionHandler(.cancel)
            return
        }
        // Same-tab file link: files navigate like any other link so they
        // render with history; directories are refused (see `openFileLink`)
        // because the native browser is address-bar-only.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           url.scheme?.lowercased() == "file",
           let owner {
            let controller = BrowserCoordinator.shared.controller(for: webView.window)
                ?? BrowserCoordinator.shared.keyController
            controller?.openFileLink(url, for: owner)
            decisionHandler(.cancel)
            return
        }
        // Content-blocker exception for the page about to load, applied
        // before the decision so the first subresource already sees the
        // right lists. Same-site reuse keeps one view across navigations
        // and cross-site swaps in a factory-fresh one; both pass through
        // here, so both converge without a reload.
        if navigationAction.targetFrame?.isMainFrame == true {
            ContentBlockerStore.shared.applyException(
                for: navigationAction.request.url,
                to: webView.configuration.userContentController
            )
        }
        decisionHandler(.allow)
    }
}
