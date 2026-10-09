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

/// Vault models and the password store's local mutations. The crypto lives
/// in the core and is covered by the Nim suite; here the store never touches
/// the service (`persistEnabled = false`), so these run headless.
@MainActor
struct PasswordStoreTests {
    private func makeStore() -> PasswordStore {
        let store = PasswordStore()
        store.persistEnabled = false
        return store
    }

    @Test("partial vault documents decode as far as they can")
    func tolerantDecode() throws {
        let data = Data(
            """
            {"sites": [
              {"id": "s1", "name": "Example", "url": "https://example.com"},
              {"id": "s2"},
              {"name": "no id"}
            ]}
            """.utf8
        )
        let vault = try #require(PasswordVault.decode(data))
        #expect(vault.sites.count == 2)
        #expect(vault.sites[0].credentials.isEmpty)
        #expect(vault.sites[0].favicon == nil)
        #expect(vault.sites[1].name == "")
        #expect(vault.sites[1].url == "")
    }

    @Test("a vault round-trips through JSON")
    func roundTrip() throws {
        let store = makeStore()
        let site = store.createSite(name: "Example", url: "https://example.com")
        _ = store.addCredential(to: site.id, username: "user@example.com", password: "s3cret!")
        let decoded = try #require(
            PasswordVault.decode(try JSONEncoder().encode(store.vault))
        )
        #expect(decoded == store.vault)
        #expect(decoded.sites[0].credentials[0].password == "s3cret!")
    }

    @Test("a strength report decodes, and garbage does not")
    func strengthDecode() {
        let good = PasswordStrength.decode(
            Data(#"{"strength": "Strong", "score": 5.25, "reason": "goodComplexity"}"#.utf8)
        )
        #expect(good?.level == .strong)
        #expect(good?.score == 5.25)
        #expect(good?.reason == "goodComplexity")
        #expect(PasswordStrength.decode(Data("{}".utf8)) == nil)
        #expect(PasswordStrength.decode(Data("[]".utf8)) == nil)
    }

    @Test("a site without a name falls back to its host")
    func siteNameFallback() {
        let store = makeStore()
        let site = store.createSite(name: "  ", url: "https://example.com/page")
        #expect(site.name == "example.com")
        #expect(site.displayName == "example.com")
        #expect(site.host == "example.com")
    }

    @Test("updating a site refuses an empty URL")
    func updateRefusesEmptyURL() {
        let store = makeStore()
        let site = store.createSite(name: "Example", url: "https://example.com")
        store.updateSite(site.id, name: "Renamed", url: "   ")
        #expect(store.site(site.id)?.url == "https://example.com")
        #expect(store.site(site.id)?.name == "Example")
        store.updateSite(site.id, name: "Renamed", url: "https://other.example")
        #expect(store.site(site.id)?.name == "Renamed")
    }

    @Test("credential pairs are added, edited, and removed per site")
    func credentialLifecycle() throws {
        let store = makeStore()
        let site = store.createSite(name: "Example", url: "https://example.com")
        let first = try #require(
            store.addCredential(to: site.id, username: "one@example.com", password: "pw1")
        )
        _ = store.addCredential(to: site.id, username: "two@example.com", password: "pw2")
        #expect(store.site(site.id)?.credentials.count == 2)

        store.updateCredential(siteID: site.id, first.id, username: "uno@example.com", password: "pw1x")
        #expect(store.site(site.id)?.credentials[0].username == "uno@example.com")

        store.deleteCredential(siteID: site.id, first.id)
        #expect(store.site(site.id)?.credentials.map(\.username) == ["two@example.com"])

        #expect(store.addCredential(to: "missing", username: "x", password: "y") == nil)
    }

    @Test("deleting a site drops its credentials with it")
    func siteDelete() {
        let store = makeStore()
        let site = store.createSite(name: "Example", url: "https://example.com")
        _ = store.addCredential(to: site.id, username: "u", password: "p")
        store.deleteSite(site.id)
        #expect(store.vault.sites.isEmpty)
    }

    @Test("remove-all clears the local vault")
    func removeAll() {
        let store = makeStore()
        _ = store.createSite(name: "Example", url: "https://example.com")
        store.removeAll()
        #expect(store.vault == .empty)
    }

    @Test("search finds a site by name, URL, or username")
    func search() {        let site = VaultSite(
            id: "s",
            name: "Example Mail",
            url: "https://mail.example.com",
            credentials: [VaultCredential(id: "c", username: "user@example.com", password: "x")]
        )
        #expect(VaultSearch.matches(site, query: "example mail"))
        #expect(VaultSearch.matches(site, query: "mail.example"))
        #expect(VaultSearch.matches(site, query: "user@example.com"))
        #expect(VaultSearch.matches(site, query: "MAIL"))
        #expect(VaultSearch.matches(site, query: ""))
        #expect(!VaultSearch.matches(site, query: "bank"))
    }

    @Test("non-web addresses fetch no icon, without touching the network")
    func faviconGating() async {
        await #expect(SiteFaviconFetcher.fetchBase64(for: URL(string: "w://about")!) == nil)
    }
}
