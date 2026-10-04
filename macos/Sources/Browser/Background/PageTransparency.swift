import WebKit

/// Lets a page be see-through, so the window background shows behind it.
///
/// Entirely opt-in, and off unless a background is actually configured: with no
/// background there is nothing to reveal, and a transparent page over the window
/// colour is not the appearance this browser had before.
///
/// Three steps, in order, and only these three:
///
/// 1. `drawsOpaquePageBackground = false` on our `BrowserWebView`, which
///    overrides `isOpaque` and clears the view's layer. `NSView` has no
///    `backgroundColor` on macOS — that is `UIView` — and `isOpaque` is
///    get-only, so the subclass override is the only way to express it. Neither
///    is sufficient on its own: WebKit paints the page's own background
///    regardless, so this alone changes nothing you can see.
/// 2. `underPageBackgroundColor = .clear`, which is public on macOS 12 and
///    controls the colour behind the page, notably in scroll-bounce areas.
/// 3. A style rule forcing `background-color: transparent` on the root
///    elements. This is the only step that actually works, and it is why this is
///    opt-in.
///
/// Expect it to be partial, and the settings pane says so. A site that sets its
/// background on a wrapper element, or paints a background image on `body`, still
/// hides the media, and there is no way to see through that without rewriting the
/// page.
///
/// Removals go through `removeAllUserScripts()` because `WKUserContentController`
/// has no `removeUserScript(_:)`. That is only safe because nothing else in the
/// app adds scripts; adding one later means this needs to become an
/// `add`/`remove` pair with the script held.
@MainActor
enum PageTransparency {
    /// Marks the style element this installs, so it can find and remove it again
    /// in a document that is already loaded.
    private static let styleID = "whatever-transparent-background"

    private static let styleRule = """
    html, body, #document {
        background-color: transparent !important;
        background-image: none !important;
    }
    """

    private static var script: WKUserScript {
        let source = """
        (() => {
            const install = () => {
                if (document.getElementById('\(styleID)')) return;
                const style = document.createElement('style');
                style.id = '\(styleID)';
                style.textContent = '\(styleRule)';
                (document.head || document.documentElement).appendChild(style);
            };
            install();
            document.addEventListener('DOMContentLoaded', install);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    /// Turns the current state onto every open page and onto future ones.
    static func apply(enabled: Bool, to webViews: [WKWebView]) {
        for webView in webViews {
            apply(enabled: enabled, to: webView)
        }
    }

    static func apply(enabled: Bool, to webView: WKWebView) {
        // Step 1. Only our own subclass can answer this; anything else keeps the
        // default rather than being poked at.
        (webView as? BrowserWebView)?.drawsOpaquePageBackground = !enabled
        // Step 2. Public, and the only one of the two that is not a no-op on its
        // own: it is what shows in scroll-bounce areas.
        webView.underPageBackgroundColor = enabled ? .clear : .windowBackgroundColor

        let controller = webView.configuration.userContentController
        if enabled {
            controller.addUserScript(script)
        } else {
            controller.removeAllUserScripts()
        }
        // Step 3. The script only runs on the next load, so the document on
        // screen is fixed separately or the toggle would appear to do nothing
        // until a navigation happened.
        webView.evaluateJavaScript(enabled ? installSource : removeSource)
    }

    private static var installSource: String {
        """
        (() => {
            const id = '\(styleID)';
            if (document.getElementById(id)) return;
            const style = document.createElement('style');
            style.id = id;
            style.textContent = '\(styleRule)';
            (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    private static var removeSource: String {
        "document.getElementById('\(styleID)')?.remove();"
    }
}