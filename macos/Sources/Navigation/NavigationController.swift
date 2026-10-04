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
        guard let owner, owner.shouldRecordHistory, let url = webView.url,
              !url.isAddresslessPage
        else {
            return
        }
        history.record(url: url, title: webView.title)
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
        // Same-tab link: load it in a fresh view through the tab, which
        // records it in the tab's own history. New-window links
        // (targetFrame == nil) keep the popup flow; forms, reloads, and
        // scripted navigations stay in place.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
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
