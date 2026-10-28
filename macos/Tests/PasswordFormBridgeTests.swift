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
import Testing
@testable import Whatever

/// Form bridge scripts: capture, lookup, and fill builders.
struct PasswordFormBridgeTests {
    @Test("the capture records password and username kinds")
    func captureKinds() {
        #expect(PasswordFormBridge.source.contains("__whateverContextField"))
        #expect(PasswordFormBridge.source.contains("input[type=password]"))
        #expect(PasswordFormBridge.source.contains("contextmenu"))
    }

    @Test("unknown answers decode as other")
    func kindDecoding() {
        #expect(PasswordFormBridge.kind(from: "password") == .password)
        #expect(PasswordFormBridge.kind(from: "USERNAME") == .username)
        #expect(PasswordFormBridge.kind(from: "other") == .other)
        #expect(PasswordFormBridge.kind(from: nil) == .other)
        #expect(PasswordFormBridge.kind(from: 42) == .other)
    }

    @Test("the lookup queries the click point for its field")
    func lookupPoint() {
        let script = PasswordFormBridge.fieldLookupScript(viewX: 120, viewY: 45)
        #expect(script.contains("document.elementFromPoint(x, y)"))
        #expect(script.contains("closest('input')"))
        #expect(script.contains("window.scrollX"))
        #expect(script.contains("visualViewport"))
    }

    @Test("the resolution prefers the captured kind")
    func resolutionPrefersCapture() {
        let script = PasswordFormBridge.fieldResolutionScript(viewX: 10, viewY: 10)
        #expect(script.contains("__whateverContextField"))
        #expect(script.contains("if (captured) return captured"))
    }

    @Test("fill scripts use the native setter and framework events")
    func fillScripts() {
        let fill = PasswordFormBridge.fillLoginScript(username: "u", password: "p")
        #expect(fill.contains("HTMLInputElement.prototype"))
        #expect(fill.contains("new Event('input'"))
        #expect(fill.contains("new Event('change'"))
        #expect(fill.contains("querySelectorAll('input[type=password]')"))

        let suggest = PasswordFormBridge.suggestFillScript(password: "p")
        #expect(suggest.contains("HTMLInputElement.prototype"))
        #expect(suggest.contains("String(filled)"))
    }

    @Test("values are JSON-escaped into the script")
    func escaping() {
        #expect(PasswordFormBridge.jsString("plain") == "\"plain\"")
        #expect(PasswordFormBridge.jsString("a\"b\\c") == "\"a\\\"b\\\\c\"")
        let script = PasswordFormBridge.fillLoginScript(
            username: "a\"b\\c", password: "p\nq")
        #expect(script.contains("a\\\"b\\\\c"))
        #expect(script.contains("p\\nq"))
        #expect(!script.contains("\"\"a"))
    }

    @Test("the source reports focus and submit through the handler")
    func formReporters() {
        #expect(PasswordFormBridge.source.contains("focusin"))
        #expect(PasswordFormBridge.source.contains("\"submit\"") || PasswordFormBridge.source.contains("'submit'"))
        #expect(PasswordFormBridge.source.contains(PasswordFormBridge.handlerName))
        #expect(PasswordFormBridge.source.contains("getBoundingClientRect"))
    }

    @Test("focus events decode with kind and rect")
    func focusDecode() {
        let event = PasswordFormBridge.LoginFormEvent.decode([
            "t": "focus",
            "kind": "password",
            "rect": ["x": 10.0, "y": 20.0, "w": 100.0, "h": 30.0, "zoom": 2.0],
        ])
        #expect(event?.kind == .focus)
        #expect(event?.fieldKind == .password)
        #expect(event?.rect == PasswordFormBridge.ViewportRect(x: 10, y: 20, width: 100, height: 30, zoom: 2))
    }

    @Test("submit events decode only with a non-empty password")
    func submitDecode() {
        #expect(
            PasswordFormBridge.LoginFormEvent.decode(
                ["t": "submit", "username": "u", "password": "p"])?.password == "p"
        )
        #expect(
            PasswordFormBridge.LoginFormEvent.decode(
                ["t": "submit", "username": "u", "password": ""]) == nil
        )
        #expect(PasswordFormBridge.LoginFormEvent.decode(["t": "focus", "kind": "other"]) == nil)
        #expect(PasswordFormBridge.LoginFormEvent.decode(["nope": 1]) == nil)
        #expect(PasswordFormBridge.LoginFormEvent.decode("focus") == nil)
    }

    @Test("degenerate rects decode as nil")
    func rectGating() {
        #expect(
            PasswordFormBridge.ViewportRect.decode(["x": 1.0, "y": 1.0, "w": 0.0, "h": 5.0]) == nil
        )
        #expect(
            PasswordFormBridge.ViewportRect.decode(["x": 1.0, "y": 1.0]) == nil
        )
    }

    @Test("anchors scale by zoom and flip to the view origin")
    func anchorFlip() {
        let rect = BrowserWebView.anchorRect(
            viewport: PasswordFormBridge.ViewportRect(x: 10, y: 20, width: 100, height: 30, zoom: 2),
            boundsHeight: 600
        )
        #expect(rect == NSRect(x: 20, y: 500, width: 200, height: 60))
        #expect(
            BrowserWebView.anchorRect(
                viewport: PasswordFormBridge.ViewportRect(x: 0, y: 0, width: 0, height: 10, zoom: 1),
                boundsHeight: 600
            ) == nil
        )
    }
}
