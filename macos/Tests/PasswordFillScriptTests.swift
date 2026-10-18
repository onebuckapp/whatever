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
import Testing
import WebKit
@testable import Whatever

/// Fill scripts against a real page: the login and suggest scripts must
/// fill visible fields and answer their verdicts, including with tricky
/// characters that need JSON escaping.
@MainActor
struct PasswordFillScriptTests {
    private func makeView() -> WKWebView {
        WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: WKWebViewConfiguration())
    }

    private func load(_ view: WKWebView, html: String, inputCount: Int = 1) async {
        view.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1:3000/"))
        // Poll for the inputs themselves: the previous (empty) document
        // already reads `complete`, so readyState alone races the commit.
        for _ in 0 ..< 200 {
            if let count = try? await view.evaluateJavaScriptSafely(
                "document.querySelectorAll('input').length") as? Int,
               count >= inputCount {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static let loginHTML = """
        <form method="POST" action="/login">
        <input id="u" name="username" type="text" autocomplete="username">
        <input id="p" name="password" type="password" autocomplete="current-password">
        <button type="submit">Sign in</button>
        </form>
        """

    private static let signupHTML = """
        <form method="POST" action="/signup">
        <input id="u" name="username" type="text" autocomplete="username">
        <input id="p1" name="password" type="password" autocomplete="new-password">
        <input id="p2" name="confirm" type="password" autocomplete="new-password">
        <button type="submit">Create</button>
        </form>
        """

    @Test("login fill answers ok and sets both fields")
    func loginFill() async throws {
        let view = makeView()
        await load(view, html: Self.loginHTML)
        let raw = try await view.evaluateJavaScriptSafely(
            PasswordFormBridge.fillLoginScript(username: "user@example.com", password: "s3cret!"))
        #expect(raw as? String == "ok")
        let user = try await view.evaluateJavaScriptSafely("document.getElementById('u').value") as? String
        let pass = try await view.evaluateJavaScriptSafely("document.getElementById('p').value") as? String
        #expect(user == "user@example.com")
        #expect(pass == "s3cret!")
    }

    @Test("suggest fill sets every password field and counts them")
    func suggestFill() async throws {
        let view = makeView()
        await load(view, html: Self.signupHTML, inputCount: 3)
        let raw = try await view.evaluateJavaScriptSafely(
            PasswordFormBridge.suggestFillScript(password: "S3cret!x"))
        #expect(raw as? String == "2")
        let first = try await view.evaluateJavaScriptSafely("document.getElementById('p1').value") as? String
        let second = try await view.evaluateJavaScriptSafely("document.getElementById('p2').value") as? String
        #expect(first == "S3cret!x")
        #expect(second == "S3cret!x")
    }

    @Test("suggest fill survives quotes, backslashes, and newlines")
    func suggestEscaping() async throws {
        let view = makeView()
        await load(view, html: Self.loginHTML)
        let tricky = "a\"b\\c$d'e"
        let raw = try await view.evaluateJavaScriptSafely(
            PasswordFormBridge.suggestFillScript(password: tricky))
        #expect(raw as? String == "1")
        let pass = try await view.evaluateJavaScriptSafely("document.getElementById('p').value") as? String
        #expect(pass == tricky)
    }

    @Test("login fill on a page with no password answers nopassword")
    func loginNoPassword() async throws {
        let view = makeView()
        await load(view, html: "<input type=text id=u>")
        let raw = try await view.evaluateJavaScriptSafely(
            PasswordFormBridge.fillLoginScript(username: "u", password: "p"))
        #expect(raw as? String == "nopassword")
    }
}
