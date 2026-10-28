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

import AppKit
import Foundation
import WebKit

/// Form detection and fill scripts for password autofill.
///
/// Mirrors `PageLinkCapture`: a tiny idempotent `contextmenu` capture
/// records the right-clicked field, and the menu reads it back with a
/// point-based `elementFromPoint` fallback for pages that never fired the
/// event. The same script also reports login-field focus (for the inline
/// credential picker) and login-form submits (for the save prompt) through
/// the `handlerName` message handler. Fill scripts set values through the
/// native property setter and dispatch `input`/`change`/`keyup` so
/// framework-bound inputs (React, Vue) observe the change. All builders are
/// pure so tests pin them without a web view.
enum PasswordFormBridge {
    /// The page variable the capture writes and the menu reads. A short
    /// string kind (`password`, `username`, `other`), never a secret.
    static let variable = "__whateverContextField"
    private static let installed = "__whateverPasswordCapture"

    /// Script-message handler the focus and submit reporters post to.
    /// Registered alongside the script in `PageScripts.rebuild`, like the
    /// hover and video relays.
    static let handlerName = "whateverPasswordForms"

    nonisolated static var source: String {
        """
        (() => {
            if (window.\(installed)) return;
            window.\(installed) = true;
            window.\(variable) = null;
            const kindOf = (target) => {
                if (!target || typeof target.closest !== "function") return "other";
                const input = target.closest("input");
                if (!input) return "other";
                const type = (input.type || "").toLowerCase();
                if (type === "password") return "password";
                const form = target.closest("form");
                const formHasPassword = form
                    ? !!form.querySelector("input[type=password]")
                    : !!document.querySelector("input[type=password]");
                if (!formHasPassword) return "other";
                if (type === "email") return "username";
                if (type === "text" || type === "" || type === "username") return "username";
                const autocomplete = (input.getAttribute("autocomplete") || "").toLowerCase();
                if (autocomplete === "username" || autocomplete === "email") return "username";
                return "other";
            };
            document.addEventListener("contextmenu", (event) => {
                try { window.\(variable) = kindOf(event.target); } catch (e) { window.\(variable) = null; }
            }, true);
            const post = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.\(handlerName);
            if (post) {
                const rectOf = (el) => {
                    try {
                        const r = el.getBoundingClientRect();
                        const zoom = (window.visualViewport && window.visualViewport.scale) || 1;
                        return {x: r.left, y: r.top, w: r.width, h: r.height, zoom: zoom};
                    } catch (e) { return null; }
                };
                // Focusing a login field offers the vault's matching
                // credentials in a native picker; the rect anchors it.
                document.addEventListener("focusin", (event) => {
                    try {
                        const kind = kindOf(event.target);
                        if (kind !== "password" && kind !== "username") return;
                        const input = event.target.closest ? event.target.closest("input") : null;
                        post.postMessage({t: "focus", kind: kind, rect: input ? rectOf(input) : null});
                    } catch (e) { /* handler gone */ }
                }, true);
                // Submitting a form that holds a password arms the save
                // prompt; the pane asks on the next committed navigation.
                document.addEventListener("submit", (event) => {
                    try {
                        const form = event.target;
                        if (!form || !form.querySelector || !form.querySelector("input[type=password]")) return;
                        const pw = form.querySelector("input[type=password]");
                        const user = form.querySelector("input[type=email],input[type=text],input:not([type]),input[autocomplete=username],input[autocomplete=email]");
                        post.postMessage({t: "submit", username: user ? user.value : "", password: pw ? pw.value : ""});
                    } catch (e) { /* handler gone */ }
                }, true);
            }
        })();
        """
    }

    nonisolated static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// What the right-clicked element is for the password menu.
    enum FieldKind: String, Equatable, Sendable {
        case password
        case username
        case other
    }

    /// Decodes the raw script answer into a kind. Anything unexpected is
    /// `other`, which hides the password menu.
    static func kind(from raw: Any?) -> FieldKind {
        guard let value = raw as? String else { return .other }
        return FieldKind(rawValue: value.lowercased()) ?? .other
    }

    /// The script the menu runs to find the right-clicked field kind.
    /// Prefers the kind the page's own `contextmenu` event captured and
    /// clears it either way so it cannot leak into the next menu.
    static func fieldResolutionScript(viewX: CGFloat?, viewY: CGFloat?) -> String {
        let coordinate: String
        if let viewX, let viewY {
            coordinate = "return \(fieldLookupScript(viewX: viewX, viewY: viewY));"
        } else {
            coordinate = "return null;"
        }
        return """
        (() => {
            const captured = window.\(variable);
            window.\(variable) = null;
            if (captured) return captured;
            \(coordinate)
        })()
        """
    }

    /// The field-kind lookup for a right-click at view coordinates with a
    /// top-left origin. Pure so tests prove the coordinate math without a
    /// web view. The menu's fallback path, not its first choice.
    static func fieldLookupScript(viewX: CGFloat, viewY: CGFloat) -> String {
        """
        (() => {
            const zoom = (window.visualViewport && window.visualViewport.scale) || 1;
            const x = \(viewX) / zoom - window.scrollX;
            const y = \(viewY) / zoom - window.scrollY;
            const el = document.elementFromPoint(x, y);
            const input = el && el.closest ? el.closest('input') : null;
            if (!input) return 'other';
            const type = (input.type || '').toLowerCase();
            if (type === 'password') return 'password';
            const form = input.closest ? input.closest('form') : null;
            const formHasPassword = form
                ? !!form.querySelector('input[type=password]')
                : !!document.querySelector('input[type=password]');
            if (!formHasPassword) return 'other';
            if (type === 'email' || type === 'text' || type === '' || type === 'username') return 'username';
            const autocomplete = (input.getAttribute('autocomplete') || '').toLowerCase();
            if (autocomplete === 'username' || autocomplete === 'email') return 'username';
            return 'other';
        })()
        """
    }

    /// Encodes a Swift string as a JavaScript string literal via JSON, so
    /// quotes, backslashes, and newlines in usernames and passwords cannot
    /// break out of the fill script. The array wrapper's brackets are
    /// stripped; the element keeps its JSON quotes, which are valid JS.
    static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              var text = String(data: data, encoding: .utf8),
              text.count >= 2
        else {
            return "\"\""
        }
        text.removeFirst()
        text.removeLast()
        return text
    }

    /// Shared setter helper: the native value setter plus framework events.
    private static var setterHelper: String {
        """
        const setVal = (el, v) => {
            if (!el || el.disabled || el.readOnly) return false;
            try {
                const proto = el.tagName === 'TEXTAREA'
                    ? window.HTMLTextAreaElement.prototype
                    : window.HTMLInputElement.prototype;
                const desc = proto && Object.getOwnPropertyDescriptor(proto, 'value');
                if (desc && desc.set) desc.set.call(el, v);
                else el.value = v;
            } catch (e) { el.value = v; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new KeyboardEvent('keyup', {bubbles: true}));
            return true;
        };
        const visible = (el) => (
            !!el && !el.disabled && !el.readOnly &&
            !!(el.offsetParent || el === document.activeElement)
        );
        """
    }

    /// Fills the first visible username and password fields. An explicit
    /// menu click always fills (plan decision), even over non-empty fields.
    /// Answers `ok`, `nopassword`, or `nofield` for the caller to beep on.
    static func fillLoginScript(username: String, password: String) -> String {
        """
        (() => {
            \(setterHelper)
            const passwords = Array.from(document.querySelectorAll('input[type=password]')).filter(visible);
            if (passwords.length === 0) return 'nopassword';
            const candidates = Array.from(document.querySelectorAll(
                'input[type=email],input[type=text],input:not([type]),input[type=username],input[autocomplete=username],input[autocomplete=email]'
            )).filter(visible);
            if (candidates.length > 0) setVal(candidates[0], \(jsString(username)));
            setVal(passwords[0], \(jsString(password)));
            passwords[0].focus();
            return 'ok';
        })()
        """
    }

    /// Fills every visible password field (login plus its confirm twin)
    /// with the suggested password. Answers the filled count as a string.
    static func suggestFillScript(password: String) -> String {
        """
        (() => {
            \(setterHelper)
            const passwords = Array.from(document.querySelectorAll('input[type=password]')).filter(visible);
            let filled = 0;
            for (const field of passwords) {
                if (setVal(field, \(jsString(password)))) filled += 1;
            }
            if (passwords.length > 0) passwords[passwords.length - 1].focus();
            return String(filled);
        })()
        """
    }

    // MARK: - Form events

    /// A focus or submit report from the page, decoded from the message
    /// handler body. Credentials travel only in submit events, and only to
    /// arm the save prompt; anything misshapen decodes as nil.
    struct LoginFormEvent: Equatable, Sendable {
        enum Kind: String, Sendable {
            case focus
            case submit
        }

        var kind: Kind
        /// The focused field, for focus events only.
        var fieldKind: FieldKind?
        /// The focused field's viewport rect, for focus events only.
        var rect: ViewportRect?
        /// The submitted pair, for submit events only.
        var username: String = ""
        var password: String = ""

        static func decode(_ body: Any) -> LoginFormEvent? {
            guard let dict = body as? [String: Any],
                  let raw = dict["t"] as? String,
                  let kind = Kind(rawValue: raw)
            else {
                return nil
            }
            switch kind {
            case .focus:
                guard let rawField = dict["kind"] as? String,
                      let fieldKind = FieldKind(rawValue: rawField.lowercased()),
                      fieldKind == .password || fieldKind == .username
                else {
                    return nil
                }
                var event = LoginFormEvent(kind: .focus, fieldKind: fieldKind)
                if let rectDict = dict["rect"] as? [String: Any] {
                    event.rect = ViewportRect.decode(rectDict)
                }
                return event
            case .submit:
                guard let username = dict["username"] as? String,
                      let password = dict["password"] as? String,
                      !password.isEmpty
                else {
                    return nil
                }
                return LoginFormEvent(kind: .submit, username: username, password: password)
            }
        }
    }

    /// A field's viewport-relative rect plus the pinch zoom, as the focus
    /// reporter posts it. Viewport-relative, so no scroll math is needed to
    /// anchor native UI: viewport points scale straight onto the view.
    struct ViewportRect: Equatable, Sendable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var zoom: CGFloat

        static func decode(_ dict: [String: Any]) -> ViewportRect? {
            guard let x = number(dict["x"]),
                  let y = number(dict["y"]),
                  let width = number(dict["w"]),
                  let height = number(dict["h"])
            else {
                return nil
            }
            let zoom = number(dict["zoom"]) ?? 1
            guard width > 0, height > 0, zoom > 0 else { return nil }
            return ViewportRect(x: x, y: y, width: width, height: height, zoom: zoom)
        }

        private static func number(_ value: Any?) -> CGFloat? {
            if let n = value as? NSNumber { return CGFloat(n.doubleValue) }
            if let n = value as? CGFloat { return n }
            if let n = value as? Double { return CGFloat(n) }
            return nil
        }
    }

    /// Anchors a viewport rect onto the view: scales by the pinch zoom and
    /// flips to the view's bottom-left origin against `boundsHeight`. Nil
    /// for degenerate rects, where the caller falls back to center.
    /// Pure so tests pin the flip without a web view.
    static func anchorRect(viewport: ViewportRect, boundsHeight: CGFloat) -> NSRect? {
        guard viewport.width > 0, viewport.height > 0, viewport.zoom > 0,
              boundsHeight > 0
        else {
            return nil
        }
        let width = viewport.width * viewport.zoom
        let height = viewport.height * viewport.zoom
        return NSRect(
            x: viewport.x * viewport.zoom,
            y: boundsHeight - (viewport.y + viewport.height) * viewport.zoom,
            width: width,
            height: height
        )
    }
}

/// Forwards login-form focus and submit reports to the owning view.
///
/// The content controller retains its message handlers, so this holds the
/// view weakly; the view holds the relay strongly, and neither direction
/// leaks. One relay per page: the script-list rebuild installs a fresh one
/// alongside the scripts.
final class PasswordAutofillRelay: NSObject, WKScriptMessageHandler {
    weak var view: BrowserWebView?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == PasswordFormBridge.handlerName,
              let view, message.webView === view,
              let event = PasswordFormBridge.LoginFormEvent.decode(message.body)
        else { return }
        Task { @MainActor [weak view] in
            guard let view else { return }
            switch event.kind {
            case .focus:
                guard let fieldKind = event.fieldKind else { return }
                view.noteLoginFieldFocus(kind: fieldKind, viewport: event.rect)
            case .submit:
                view.onLoginSubmitted?(event.username, event.password)
            }
        }
    }
}
