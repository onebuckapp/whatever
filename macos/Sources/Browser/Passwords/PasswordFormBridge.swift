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

import Foundation
import WebKit

/// Form detection and fill scripts for password autofill.
///
/// Mirrors `PageLinkCapture`: a tiny idempotent `contextmenu` capture
/// records the right-clicked field, and the menu reads it back with a
/// point-based `elementFromPoint` fallback for pages that never fired the
/// event. Fill scripts set values through the native property setter and
/// dispatch `input`/`change`/`keyup` so framework-bound inputs (React, Vue)
/// observe the change. All builders are pure so tests pin them without a
/// web view.
enum PasswordFormBridge {
    /// The page variable the capture writes and the menu reads. A short
    /// string kind (`password`, `username`, `other`), never a secret.
    static let variable = "__whateverContextField"
    private static let installed = "__whateverPasswordCapture"

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
}
