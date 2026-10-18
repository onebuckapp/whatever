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
}
