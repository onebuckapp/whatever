import WebKit

/// Creates `WKWebView` instances. Every page gets a fresh process pool,
/// so a discarded page's processes die with its view instead of being
/// kept for WebKit's back/forward cache. History is owned by
/// `BrowserTab` as a plain URL array, and Back/Forward re-access the
/// address with a new view. Storage is *not* per page: regular tabs
/// share the persistent default store (cookies survive navigation),
/// private tabs share one isolated non-persistent store per tab.
enum WebViewFactory {
    /// `MainActor` because the settings it reads live on a `MainActor` store,
    /// and because a `WKWebView` has to be built on the main thread anyway.
    @MainActor
    static func makeWebView(
        mode: BrowserPrivacyMode,
        dataStore: WKWebsiteDataStore
    ) -> BrowserWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Fresh pool per page: nothing outlives the view.
        configuration.processPool = WKProcessPool()
        // Served from memory by HomepageSchemeHandler; whtvr://about is
        // the homepage and always shows the bundled markup.
        configuration.setURLSchemeHandler(HomepageSchemeHandler(), forURLScheme: "whtvr")
        // The half of the user's web settings WebKit only reads here. The other
        // half is applied by `applyLiveWebSettings` once the view exists.
        SettingsStore.shared.settings.web.apply(to: configuration)
        // Compiled content-blocker lists. The QR popup builds its own
        // configuration for a non-interactive SVG view and never sees these.
        if SettingsStore.shared.settings.adblock.enabled {
            for list in ContentBlockerStore.shared.lists {
                configuration.userContentController.add(list)
            }
        }
        // Find-in-page bridge: every page starts with the namespace, whether
        // or not the bar is open. `PageTransparency` re-adds this whenever it
        // touches the script list, so toggling transparency never strips it
        // from future loads.
        configuration.userContentController.addUserScript(FindBridge.script)
        let webView = BrowserWebView(frame: .zero, configuration: configuration)
        // The live half too, not just the configuration half. Without this a page
        // opened after the user changed their zoom or user agent came up ignoring
        // both until some unrelated change fanned `web` out and pushed them onto
        // every open view.
        SettingsStore.shared.settings.web.apply(toWebView: webView)
        // Read here rather than pushed later, so a page built after the setting
        // changed is already see-through instead of opaque until something else
        // happens to it.
        let background = SettingsStore.shared.settings.appearance.background
        PageTransparency.apply(
            enabled: background.isActive && background.showThroughPages,
            to: webView
        )
        return webView
    }
}
