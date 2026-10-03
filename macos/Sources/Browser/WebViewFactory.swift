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
        return BrowserWebView(frame: .zero, configuration: configuration)
    }
}
