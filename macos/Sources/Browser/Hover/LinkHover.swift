import WebKit

/// Reports the hovered link to native code, for the status bubble.
///
/// A capture-phase `mouseover`/`mouseout` pair resolves
/// `closest('a[href]')` from the event target — the browser's own hit test,
/// so no coordinate mapping that layout, scroll, or zoom could skew — and
/// posts the href through a script message. Reports only changes: `mouseover`
/// fires on every element boundary, and without the guard the bubble would
/// drown in repeats. `mouseleave` on the root covers the pointer leaving the
/// window from inside a link, which fires no `mouseout`.
///
/// Always on, like the find bridge and the link capture: tiny, idempotent,
/// and harmless on pages with no links.
enum LinkHover {
    static let handlerName = "whateverLinkHover"

    private static let installed = "__whateverLinkHover"

    static var source: String {
        """
        (() => {
            if (window.\(installed)) return;
            window.\(installed) = true;
            const post = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.\(handlerName);
            if (!post) return;
            let current = null;
            const report = (href) => {
                if (href === current) return;
                current = href;
                try { post.postMessage(href); } catch (e) { /* gone */ }
            };
            const anchorOf = (node) => (
                node && typeof node.closest === "function" ? node.closest("a[href]") : null
            );
            document.addEventListener("mouseover", (event) => {
                const link = anchorOf(event.target);
                report(link ? link.href : null);
            }, true);
            document.addEventListener("mouseout", (event) => {
                const from = anchorOf(event.target);
                if (!from) return;
                const to = anchorOf(event.relatedTarget);
                if (from === to) return;
                report(to ? to.href : null);
            }, true);
            // `documentElement` is still null at document start: without `?.`
            // this line throws, the mouseleave notice never attaches, and a
            // pointer leaving the window from inside a link leaves a stale
            // bubble behind. The mouseover/mouseout pair above already ran,
            // so hover itself survives either way.
            document.documentElement?.addEventListener("mouseleave", () => report(null));
        })();
        """
    }

    static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

/// Forwards hover messages to the owning view.
///
/// The content controller retains its message handlers, so this holds the
/// view weakly; the view holds the relay strongly, and neither direction
/// leaks. One relay per page: the script-list rebuild installs a fresh one
/// alongside the scripts.
final class LinkHoverRelay: NSObject, WKScriptMessageHandler {
    weak var view: BrowserWebView?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == LinkHover.handlerName,
              let view, message.webView === view
        else { return }
        Task { @MainActor [weak view] in
            guard let view else { return }
            if let href = message.body as? String, !href.isEmpty,
               let url = URL(string: href)
            {
                view.onLinkHover?(url)
            } else {
                view.onLinkHover?(nil)
            }
        }
    }
}
