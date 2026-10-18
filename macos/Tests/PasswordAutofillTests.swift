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

/// Host matching for autofill: exact first, base-domain fallback.
struct PasswordAutofillTests {
    private func site(id: String, url: String, name: String = "", user: String = "user") -> VaultSite {
        VaultSite(
            id: id, name: name, url: url,
            credentials: [VaultCredential(id: "c-\(id)", username: user, password: "pw")])
    }

    @Test("normalization lowercases and strips www and trailing dot")
    func normalization() {
        #expect(PasswordAutofill.normalizeHost("WWW.Example.COM.") == "example.com")
        #expect(PasswordAutofill.normalizeHost(url: URL(string: "https://Login.Example.com/x")) == "login.example.com")
        #expect(PasswordAutofill.normalizeHost(url: URL(string: "w://about")) == "")
        #expect(PasswordAutofill.normalizeHost(url: nil) == "")
        #expect(PasswordAutofill.normalizeHost("") == "")
    }

    @Test("base domain keeps the last two labels")
    func baseDomain() {
        #expect(PasswordAutofill.baseDomain(of: "login.example.com") == "example.com")
        #expect(PasswordAutofill.baseDomain(of: "example.com") == "example.com")
        #expect(PasswordAutofill.baseDomain(of: "localhost") == "localhost")
        #expect(PasswordAutofill.baseDomain(of: "") == "")
    }

    @Test("exact hosts beat base-domain fallback")
    func exactFirst() {
        let sites = [
            site(id: "base", url: "https://example.com"),
            site(id: "exact", url: "https://login.example.com"),
        ]
        let matched = PasswordAutofill.sites(matchingHost: "login.example.com", from: sites)
        #expect(matched.map(\.id) == ["exact", "base"])
    }

    @Test("subdomains fall back to the base domain")
    func fallback() {
        let sites = [site(id: "base", url: "https://example.com")]
        #expect(PasswordAutofill.sites(matchingHost: "login.example.com", from: sites).map(\.id) == ["base"])
        #expect(PasswordAutofill.sites(matchingHost: "other.com", from: sites).isEmpty)
        #expect(PasswordAutofill.sites(matchingHost: "", from: sites).isEmpty)
    }

    @Test("unrelated domains never match")
    func noCrossMatch() {
        let sites = [site(id: "a", url: "https://example.com")]
        #expect(PasswordAutofill.sites(matchingHost: "example.org", from: sites).isEmpty)
        #expect(PasswordAutofill.sites(matchingHost: "notexample.com", from: sites).isEmpty)
    }

    @Test("menu titles prefer the username")
    func menuTitles() {
        let named = PasswordAutofill.Match(
            siteID: "s", siteName: "Example",
            credential: VaultCredential(id: "c", username: "user@example.com", password: "x"))
        #expect(PasswordAutofill.menuTitle(for: named) == "user@example.com")
        let blank = PasswordAutofill.Match(
            siteID: "s", siteName: "Example",
            credential: VaultCredential(id: "c", username: "  ", password: "x"))
        #expect(PasswordAutofill.menuTitle(for: blank) == "Example")
    }

    @Test("password menu plan follows the locked decisions")
    func menuPlan() {
        let matches = [
            PasswordAutofill.Match(
                siteID: "s", siteName: "Example",
                credential: VaultCredential(id: "c", username: "u", password: "p")),
        ]
        let unlocked = PasswordMenuContext(isUnlocked: true, matches: matches)
        let locked = PasswordMenuContext(isUnlocked: false, matches: matches)
        let empty = PasswordMenuContext(isUnlocked: true, matches: [])

        let passwordUnlocked = BrowserWebView.passwordMenuPlan(kind: .password, context: unlocked)
        #expect(passwordUnlocked.showsFillSubmenu && passwordUnlocked.showsSuggestItem)
        #expect(passwordUnlocked.fillTitles == ["u"])

        let usernameUnlocked = BrowserWebView.passwordMenuPlan(kind: .username, context: unlocked)
        #expect(usernameUnlocked.showsFillSubmenu && !usernameUnlocked.showsSuggestItem)

        let passwordLocked = BrowserWebView.passwordMenuPlan(kind: .password, context: locked)
        #expect(!passwordLocked.showsFillSubmenu && passwordLocked.showsUnlockItem && passwordLocked.showsSuggestItem)

        let usernameLocked = BrowserWebView.passwordMenuPlan(kind: .username, context: locked)
        #expect(usernameLocked.showsUnlockItem && !usernameLocked.showsSuggestItem)

        let passwordEmpty = BrowserWebView.passwordMenuPlan(kind: .password, context: empty)
        #expect(!passwordEmpty.showsFillSubmenu && !passwordEmpty.showsUnlockItem && passwordEmpty.showsSuggestItem)

        let other = BrowserWebView.passwordMenuPlan(kind: .other, context: unlocked)
        #expect(!other.showsFillSubmenu && !other.showsSuggestItem && !other.showsUnlockItem)
    }

    @Test("overflow past ten rows shows the manage row")
    func overflow() {
        let matches = (0 ..< 12).map { i in
            PasswordAutofill.Match(
                siteID: "s\(i)", siteName: "Site \(i)",
                credential: VaultCredential(id: "c\(i)", username: "u\(i)", password: "p"))
        }
        let plan = BrowserWebView.passwordMenuPlan(
            kind: .password, context: PasswordMenuContext(isUnlocked: true, matches: matches))
        #expect(plan.fillTitles.count == BrowserWebView.maxFillRows)
        #expect(plan.showsManageRow)
    }
}
