import WebKit

/// Rebuilds a page's user-script list from current settings.
///
/// `WKUserContentController` has no remove-single-script, so every feature
/// toggle rebuilds the whole list: the find bridge, the link capture, and
/// the hover reporter always, then each opt-in script whose setting is on.
/// Message handlers are rebuilt the same way (`removeScriptMessageHandler`
/// before `add` keeps re-adding idempotent). Future loads get exactly this
/// set; each feature separately patches the document already on screen,
/// because a live document keeps its already-evaluated scripts.
@MainActor
enum PageScripts {
    static func rebuild(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(FindBridge.script)
        controller.addUserScript(PageLinkCapture.script)
        controller.addUserScript(LinkHover.script)
        controller.removeScriptMessageHandler(forName: LinkHover.handlerName)
        if let browserView = webView as? BrowserWebView {
            let relay = LinkHoverRelay()
            relay.view = browserView
            browserView.hoverRelay = relay
            controller.add(relay, name: LinkHover.handlerName)
        }
        let settings = SettingsStore.shared.settings
        let background = settings.appearance.background
        if background.isActive && background.showThroughPages {
            controller.addUserScript(PageTransparency.script)
        }
        if settings.search.cleanResultLinks {
            controller.addUserScript(SearchLinkGuard.script)
        }
    }
}
