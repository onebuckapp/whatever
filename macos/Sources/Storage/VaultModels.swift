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

/// The decrypted vault as Swift owns it.
///
/// The core only ever sees this as one opaque JSON object: it validates the
/// shape (object, not scalar) and encrypts the bytes. Everything about sites,
/// credentials, and favicons below is a Swift-side decision.
///
/// Decoding is tolerant like the other stored models: a document from an
/// older build, or a hand-edited one, reads as far as it can rather than
/// failing the whole vault.
struct PasswordVault: Codable, Equatable {
    var sites: [VaultSite]

    static let empty = PasswordVault(sites: [])

    private enum CodingKeys: String, CodingKey {
        case sites
    }

    init(sites: [VaultSite]) {
        self.sites = sites
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sites = (try? container.decode([FailableSite].self, forKey: .sites))?.compactMap(\.value) ?? []
    }

    static func decode(_ data: Data) -> PasswordVault? {
        try? JSONDecoder().decode(PasswordVault.self, from: data)
    }

    /// One malformed site costs that site, not the vault.
    private struct FailableSite: Decodable {
        let value: VaultSite?

        init(from decoder: Decoder) throws {
            value = try? VaultSite(from: decoder)
        }
    }
}

/// One website in the vault, with every credential pair kept for it.
struct VaultSite: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var url: String
    /// Processed favicon PNG, base64, stored encrypted with the vault.
    var favicon: String?
    var credentials: [VaultCredential]
    /// Unix seconds, for a stable tiebreak and future "sort by added".
    var createdAt: Int64?
    var updatedAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, name, url, favicon, credentials, createdAt, updatedAt
    }

    init(
        id: String,
        name: String,
        url: String,
        favicon: String? = nil,
        credentials: [VaultCredential] = [],
        createdAt: Int64? = nil,
        updatedAt: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.favicon = favicon
        self.credentials = credentials
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        favicon = try? container.decode(String.self, forKey: .favicon)
        credentials = (try? container.decode([FailableCredential].self, forKey: .credentials))?
            .compactMap(\.value) ?? []
        createdAt = try? container.decode(Int64.self, forKey: .createdAt)
        updatedAt = try? container.decode(Int64.self, forKey: .updatedAt)
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if !host.isEmpty { return host }
        return url.isEmpty ? "Untitled site" : url
    }

    var host: String {
        URL(string: url)?.host?.lowercased() ?? ""
    }
}

/// One username + password pair inside a site.
struct VaultCredential: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var username: String
    var password: String

    private enum CodingKeys: String, CodingKey {
        case id, username, password
    }

    init(id: String, username: String, password: String) {
        self.id = id
        self.username = username
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = (try? container.decode(String.self, forKey: .username)) ?? ""
        password = (try? container.decode(String.self, forKey: .password)) ?? ""
    }
}

/// One malformed credential costs that pair, not the site.
private struct FailableCredential: Decodable {
    let value: VaultCredential?

    init(from decoder: Decoder) throws {
        value = try? VaultCredential(from: decoder)
    }
}

/// A blackpaper score as the core reports it: `{"strength","score","reason"}`.
struct PasswordStrength: Equatable, Sendable {
    enum Level: String, Sendable {
        case weak
        case medium
        case strong
    }

    let level: Level
    let score: Double
    let reason: String

    static func decode(_ data: Data) -> PasswordStrength? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawLevel = root["strength"] as? String,
              let level = Level(rawValue: rawLevel.lowercased())
        else {
            return nil
        }
        return PasswordStrength(
            level: level,
            score: (root["score"] as? Double) ?? 0,
            reason: (root["reason"] as? String) ?? ""
        )
    }
}

/// Sidebar search over the vault.
///
/// One haystack per site — name, URL, and every stored username — matched
/// with the settings filter's all-words-substring rule, so a site is found
/// by any of them.
enum VaultSearch {
    static func haystack(for site: VaultSite) -> String {
        ([site.name, site.url] + site.credentials.map(\.username)).joined(separator: " ")
    }

    static func matches(_ site: VaultSite, query: String) -> Bool {
        SettingsFilter.matches(query: query, haystack: haystack(for: site))
    }
}
