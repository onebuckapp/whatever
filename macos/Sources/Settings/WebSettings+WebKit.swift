import WebKit

/// Translating `AppSettings.WebSettings` into WebKit.
///
/// Split in two because WebKit only allows it in two ways. A `WKWebView` copies
/// its configuration when it is initialised and returns a *copy* from
/// `configuration`, so nothing under the configuration — `preferences` included —
/// can be changed on a live view. Those settings therefore apply to the next page
/// a view is built for. Properties on `WKWebView` itself can be set at any time,
/// and `apply(toWebView:)` pushes them onto open pages.
///
/// Not every WebKit property is available on macOS. `allowsContentJavaScript` and
/// `allowsInlineMediaPlayback`, for instance, are declared inside
/// `#if TARGET_OS_IPHONE`; only the former has a usable stand-in
/// (`WKWebpagePreferences.allowsContentJavaScript`), and the second has no macOS
/// equivalent at all, so Whatever does not offer it.
extension AppSettings.WebSettings {
    /// Applies everything WebKit reads at view-construction time.
    ///
    /// Called from `WebViewFactory`, so a newly created page already carries the
    /// user's preferences.
    func apply(to configuration: WKWebViewConfiguration) {
        let preferences = configuration.preferences
        preferences.javaScriptCanOpenWindowsAutomatically = javaScriptCanOpenWindowsAutomatically
        preferences.isFraudulentWebsiteWarningEnabled = fraudulentWebsiteWarningEnabled
        preferences.minimumFontSize = minimumFontSize
        preferences.isSiteSpecificQuirksModeEnabled = siteSpecificQuirksModeEnabled
        preferences.isElementFullscreenEnabled = elementFullscreenEnabled
        preferences.tabFocusesLinks = tabFocusesLinks

        configuration.upgradeKnownHostsToHTTPS = upgradeKnownHostsToHTTPS
        configuration.limitsNavigationsToAppBoundDomains = limitsNavigationsToAppBoundDomains
        configuration.suppressesIncrementalRendering = suppressesIncrementalRendering
        configuration.applicationNameForUserAgent = applicationNameForUserAgent

        let page = WKWebpagePreferences()
        page.allowsContentJavaScript = allowsJavaScript
        if #available(macOS 15.2, *) {
            // `.keepAsRequested` leaves WebKit's behaviour alone. The other cases
            // all try to upgrade or re-request, which breaks `whtvr://`: it is
            // Whatever's own scheme, served by its own handler, and there is no
            // HTTPS version of it to fall back to.
            page.preferredHTTPSNavigationPolicy = .keepAsRequested
        }
        configuration.defaultWebpagePreferences = page
    }

    /// Applies the settings WebKit reads from a live view.
    ///
    /// Clamped rather than trusted: a hand-edited store could carry a zoom of
    /// zero, and WebKit's documented range for `pageZoom` is 0.25...5.
    func apply(toWebView webView: WKWebView) {
        webView.pageZoom = min(max(pageZoom, 0.25), 5)
        webView.allowsLinkPreview = allowsLinkPreview
        webView.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        webView.allowsMagnification = allowsMagnification
        webView.customUserAgent = customUserAgent
    }
}