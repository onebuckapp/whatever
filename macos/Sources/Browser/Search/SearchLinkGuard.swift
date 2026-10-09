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

import WebKit

/// Stops search engines swapping result links for tracker hops on press.
///
/// Google, Bing, DuckDuckGo and friends rewrite a result's `href` in a
/// `mousedown` handler: the click still lands on the destination (their
/// redirect endpoint answers server-side), but Back lands on the tracker,
/// and Copy Link copies the tracker. This script registers a capture-phase
/// `mousedown` listener on `window`, which fires before any page listener
/// no matter when it registered, and calls `stopImmediatePropagation` —
/// but only for presses on links, and only on result pages. The engines'
/// own UI (suggestions, menus) is mostly not link-targeted, and everything
/// outside the guarded hosts is untouched.
///
/// What it does not do, deliberately: decode destinations client-side
/// (that would be decoding-to-navigate in the page), touch keyboard
/// activation (Enter fires no `mousedown`; the history tracker skip is the
/// backstop there), or `preventDefault` anything (navigation must proceed).
///
/// Injected scripts are exempt from page Content-Security-Policy, so the
/// engines cannot block this. Cost is one capture listener.
@MainActor
enum SearchLinkGuard {
    /// Hostnames the guard activates on, as JavaScript regex sources.
    ///
    /// Kept as data rather than baked into the script so tests pin the
    /// coverage without parsing JavaScript. Google needs the open tail:
    /// `google.co.uk` and friends share only the `google.` second level,
    /// capped at two labels so `google.com.evil.example` does not arm it.
    /// A residual over-match merely arms the guard on a page with no engine
    /// rewriters — the fail-safe direction.
    ///
    /// Nonisolated: pure data, so tests can pin it without the main actor.
    nonisolated static let guardedHostPatterns = [
        #"(^|\.)google\.[a-z]+(\.[a-z]+)?$"#,
        #"(^|\.)bing\.com$"#,
        #"(^|\.)duckduckgo\.com$"#,
        #"(^|\.)yahoo\.com$"#,
        #"^search\.brave\.com$"#,
        #"(^|\.)startpage\.com$"#,
        #"(^|\.)ecosia\.org$"#,
    ]

    /// Marks the installed handler on the page's window, so re-injection
    /// (next load, or the toggle flipping live) never double-registers,
    /// and so the removal source below can find and detach it again.
    private static let marker = "__whateverLinkGuard"

    /// Nonisolated with the patterns: a pure string build, testable off the
    /// main actor.
    nonisolated static var source: String {
        let regexes = guardedHostPatterns.map { "/\($0)/" }.joined(separator: ", ")
        return """
        (() => {
            if (window.\(marker)) return;
            let host = "";
            try { host = window.location.hostname.toLowerCase(); } catch (e) { return; }
            const guarded = [\(regexes)].some((re) => re.test(host));
            if (!guarded) return;
            const onMousedown = (event) => {
                const target = event.target;
                const link = target && typeof target.closest === "function"
                    ? target.closest("a")
                    : null;
                if (!link) return;
                event.stopImmediatePropagation();
            };
            window.\(marker) = onMousedown;
            window.addEventListener("mousedown", onMousedown, true);
        })();
        """
    }

    /// Main-actor bound: `WKUserScript` construction is a UI API.
    static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// Turns the current state onto every open page and onto future ones.
    static func apply(enabled: Bool, to webViews: [WKWebView]) {
        for webView in webViews {
            apply(enabled: enabled, to: webView)
        }
    }

    static func apply(enabled: Bool, to webView: WKWebView) {
        // The script list is shared with page transparency: rebuilding goes
        // through one place so the two toggles never strip each other.
        PageScripts.rebuild(on: webView)
        // The script only runs on the next load, so the document on screen
        // is patched separately or the toggle would appear to do nothing
        // until a navigation happened. Re-running install is idempotent via
        // the marker; remove detaches the handler the marker names.
        webView.evaluateJavaScript(enabled ? source : removeSource)
    }

    private static var removeSource: String {
        """
        (() => {
            const guard = window.\(marker);
            if (!guard) return;
            window.removeEventListener("mousedown", guard, true);
            delete window.\(marker);
        })();
        """
    }
}
