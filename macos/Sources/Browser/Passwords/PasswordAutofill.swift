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

/// Host matching for password autofill: exact host first, then base-domain
/// fallback, so `login.example.com` finds a vault site kept for
/// `example.com`.
///
/// Pure and synchronous. Normalization (lowercase, one leading `www.`,
/// trailing dot) lives here so the store and the menu share one rule.
/// The base-domain split is a naive last-two-labels cut with no
/// public-suffix list, which the plan accepts for V1.
enum PasswordAutofill {
    /// Lowercases, drops a trailing dot, and strips one leading `www.`.
    /// Empty for nil, blank, or unparseable input.
    static func normalizeHost(_ host: String?) -> String {
        guard var value = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return ""
        }
        if value.hasSuffix(".") {
            value = String(value.dropLast())
        }
        if value.hasPrefix("www.") {
            value = String(value.dropFirst(4))
        }
        return value
    }

    /// The host from a page URL, normalized for matching. Empty when the
    /// URL has no http(s) host (w://, about:blank, file://).
    static func normalizeHost(url: URL?) -> String {
        guard let url, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return ""
        }
        return normalizeHost(url.host)
    }

    /// Naive base domain: the last two dot-separated labels.
    /// `login.example.com` becomes `example.com`; `example.com` stays;
    /// single-label hosts and IP literals return themselves.
    static func baseDomain(of host: String) -> String {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else { return "" }
        let parts = normalized.split(separator: ".")
        guard parts.count > 2 else { return normalized }
        return parts.suffix(2).joined(separator: ".")
    }

    /// Sites matching `host`: exact-host sites first (sorted by display
    /// name), then base-domain sites that did not already match exactly.
    static func sites(matchingHost host: String, from sites: [VaultSite]) -> [VaultSite] {
        let want = normalizeHost(host)
        guard !want.isEmpty else { return [] }
        let byName: (VaultSite, VaultSite) -> Bool = {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let exact = sites.filter { normalizeHost($0.host) == want }.sorted(by: byName)
        let base = baseDomain(of: want)
        guard !base.isEmpty, base != want else { return exact }
        let exactIDs = Set(exact.map(\.id))
        let fallback = sites.filter {
            !exactIDs.contains($0.id) && normalizeHost($0.host) == base
        }.sorted(by: byName)
        return exact + fallback
    }

    /// One credential plus the site that owns it, for menu rows.
    struct Match: Equatable, Sendable {
        let siteID: String
        let siteName: String
        let credential: VaultCredential
    }

    /// Every credential of every matching site, in site order.
    static func credentials(matchingHost host: String, from allSites: [VaultSite]) -> [Match] {
        Self.sites(matchingHost: host, from: allSites).flatMap { site in
            site.credentials.map { Match(siteID: site.id, siteName: site.displayName, credential: $0) }
        }
    }

    /// Row title for a match: the username, or the site name when the
    /// username is empty (an auto-created Suggest entry starts that way).
    static func menuTitle(for match: Match) -> String {
        let username = match.credential.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? match.siteName : username
    }
}

/// Synchronous snapshot of vault state for the page on screen.
///
/// Built by the hosting pane (which owns the tab and the store); the view
/// only lays out from it, so the view never touches the store directly.
struct PasswordMenuContext: Equatable, Sendable {
    var isUnlocked: Bool
    var matches: [PasswordAutofill.Match]
}
