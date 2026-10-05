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
        webView.window?.title = "Loading…"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.window?.title = webView.title ?? "New Tab"
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
        webView.window?.title = "Failed to Load"
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
        webView.window?.title = "Failed to Load"
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
        webView.window?.title = "Reloading…"
        owner?.reloadAfterContentProcessTermination()
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
        // A link that asks for a new window, whether `target="_blank"` or a
        // scripted `window.open`, arrives here with no target frame. Both are
        // handled by opening a real tab and cancelling, rather than by answering
        // `createWebViewWith`: WebKit performs the navigation it delegates only
        // after that call returns, by which point the new tab is already
        // selected and loading its own address, so the popup lands on the
        // homepage rather than the page that opened it.
        if navigationAction.targetFrame == nil,
           navigationAction.navigationType != .backForward,
           let owner {
            guard NavigationPolicy.canLoadInPage(navigationAction.request) else {
                // A scheme the web view cannot draw, such as mailto: or tel:.
                // The tab is never opened; the link goes to the app that handles
                // it, which is what a click on it means anywhere else.
                NavigationPolicy.handOffToSystem(url)
                decisionHandler(.cancel)
                return
            }
            openPopup(url, from: webView, owner: owner)
            decisionHandler(.cancel)
            return
        }
        // Same-tab link: load it in a fresh view through the tab, which
        // records it in the tab's own history. Forms, reloads, and scripted
        // navigations stay in place.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "whtvr"].contains(scheme),
           let owner {
            owner.navigate(to: url)
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
