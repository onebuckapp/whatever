import WebKit

/// Lets a page be see-through, so the window background shows behind it.
///
/// Only the style rule is opt-in. The two view steps below run on every
/// page unconditionally: loaded pages paint their own backgrounds whatever
/// the view says, so they change nothing on screen except the loading flash
/// and scroll-bounce areas, which show the window instead of white, and
/// pages that are natively transparent.
///
/// Three steps, in order:
///
/// 1. `drawsOpaquePageBackground = false` on our `BrowserWebView`, which
///    overrides `isOpaque` and clears the view's layer. `NSView` has no
///    `backgroundColor` on macOS — that is `UIView` — and `isOpaque` is
///    get-only, so the subclass override is the only way to express it.
/// 2. `underPageBackgroundColor = .clear`, which is public on macOS 12 and
///    controls the colour behind the page, notably in scroll-bounce areas
///    and before the first paint.
/// 3. A style rule forcing `background-color: transparent` on the root
///    elements (the opt-in half). This is the only step that reveals the
///    background through a page that paints its own, which is why the
///    setting gates just this one.
///
/// Expect the opt-in to be partial, and the settings pane says so. A site
/// that sets its background on a wrapper element, or paints a background
/// image on `body`, still hides the media, and there is no way to see
/// through that without rewriting the page.
///
/// Removals go through `removeAllUserScripts()` because `WKUserContentController`
/// has no `removeUserScript(_:)`. That call also takes the find-in-page bridge
/// `WebViewFactory` installs, so every toggle re-adds the bridge first and the
/// transparency script second: toggling never strips find from future loads.
/// (A live document keeps its already-evaluated scripts; the list only gates
/// what future pages start with.)
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
        // Steps 1 and 2 run whether or not the style rule is wanted: the
        // view never paints an opaque backdrop of its own, so the loading
        // flash shows the window behind the page instead of white.
        (webView as? BrowserWebView)?.drawsOpaquePageBackground = false
        webView.underPageBackgroundColor = .clear

        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(FindBridge.script)
        if enabled {
            controller.addUserScript(script)
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