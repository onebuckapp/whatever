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

import CryptoKit
import Foundation
import WebKit

/// Everything one profile owns app-side, built once and shared by every
/// window on that profile.
///
/// Each member is bound to the profile's store connection (or, for the
/// cookie jar, partitioned by WebKit), so a window that holds a context
/// cannot read or write another profile's data no matter which members it
/// reaches through. Members are created eagerly: the cost is a handful of
/// small objects and one XPC connection, and lazy creation would only move
/// first-use latency onto a keystroke or a tab open.
@MainActor
final class ProfileContext {
    let profile: BrowserProfile
    let client: StoreClient
    let settings: SettingsStore
    let history: StoreHistoryRecorder
    let passwords: PasswordStore
    let bookmarks: BookmarkStore
    let downloads: DownloadsStore
    let feeds: FeedReaderStore
    /// The profile's cookie jar. See `cookieJar(for:)`.
    let dataStore: WKWebsiteDataStore

    init(profile: BrowserProfile, client: StoreClient) {
        self.profile = profile
        self.client = client
        self.settings = SettingsStore(client: client)
        self.history = StoreHistoryRecorder(client: client, settings: settings)
        self.passwords = PasswordStore(client: client)
        self.bookmarks = BookmarkStore(client: client)
        self.downloads = DownloadsStore(client: client)
        self.feeds = FeedReaderStore(client: client)
        self.dataStore = Self.cookieJar(for: profile.id)
    }

    /// The cookie jar for a profile id.
    ///
    /// The default profile keeps WebKit's default store: its cookies
    /// predate profiles, and moving them would log the user out of every
    /// site on upgrade. Every other profile gets a partitioned persistent
    /// store, keyed by a UUID derived from the profile id so the mapping
    /// is stable across launches without storing another identifier
    /// anywhere. Private windows never come here: they use a
    /// non-persistent store, exactly as before.
    static func cookieJar(for profileID: String) -> WKWebsiteDataStore {
        guard profileID != BrowserProfile.defaultID else {
            return .default()
        }
        return WKWebsiteDataStore(forIdentifier: dataStoreID(for: profileID))
    }

    /// A stable UUID for a profile id: the first 16 bytes of its SHA-256,
    /// with the version and variant bits set so it reads as a name-based
    /// (v5) UUID rather than 16 arbitrary bytes.
    static func dataStoreID(for profileID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(profileID.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress!) as UUID
        }
    }
}

/// Owns the profile list and hands out one context per profile.
///
/// The core owns the registry; this mirrors it for the UI and keeps the
/// per-profile objects. Failing open: when the service cannot be reached,
/// the list stays empty and `defaultProfile` synthesizes the built-in one,
/// so the app still opens a window (whose store calls fail the way they do
/// today with the service down) instead of refusing to launch.
@MainActor
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published private(set) var profiles: [BrowserProfile] = []
    @Published private(set) var isLoaded = false
    private(set) var lastError: String?

    private var clients: [String: StoreClient] = [:]
    private var contexts: [String: ProfileContext] = [:]

    private init() {}

    /// First-launch sequence: migrates a legacy install in the service and
    /// loads the registry. Called once, before settings and the session.
    func startup() async {
        do {
            let data = try await StoreClient.shared.profilesEnsure()
            profiles = BrowserProfile.decodeRegistry(data) ?? []
            lastError = nil
        } catch {
            profiles = []
            lastError = error.localizedDescription
        }
        isLoaded = true
    }

    /// Reloads the registry after a create, rename, or delete.
    func refresh() async {
        do {
            let data = try await StoreClient.shared.profilesList()
            profiles = BrowserProfile.decodeRegistry(data) ?? []
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The profile new windows open into: most recently used, else the
    /// built-in default. Never nil, so callers never branch on "no
    /// profiles", even when the service is down.
    var defaultProfile: BrowserProfile {
        profiles.max { $0.lastUsedAt < $1.lastUsedAt }
            ?? BrowserProfile(
                id: BrowserProfile.defaultID,
                name: "Default",
                createdAt: .now,
                lastUsedAt: .now
            )
    }

    func profile(withID id: String) -> BrowserProfile? {
        profiles.first { $0.id == id }
    }

    /// The store connection for a profile, opened on first use. One
    /// connection per profile: the service binds the profile to the
    /// connection, so sharing a client is sharing the binding.
    func client(for id: String) -> StoreClient {
        if let existing = clients[id] {
            return existing
        }
        let made = StoreClient(profileId: id)
        clients[id] = made
        return made
    }

    /// Everything the profile owns app-side, built once per profile.
    func context(for profile: BrowserProfile) -> ProfileContext {
        if let existing = contexts[profile.id] {
            return existing
        }
        let made = ProfileContext(profile: profile, client: client(for: profile.id))
        contexts[profile.id] = made
        return made
    }

    /// Creates a profile and reloads the registry, returning the new entry.
    @discardableResult
    func createProfile(name: String) async throws -> BrowserProfile {
        let id = UUID().uuidString
        try await StoreClient.shared.profilesCreate(id: id, name: name)
        await refresh()
        guard let made = profile(withID: id) else {
            throw StoreErrors.unavailable()
        }
        return made
    }

    /// Renames a profile's display name and reloads the registry. The
    /// directory — and every store in it — is untouched.
    func renameProfile(id: String, name: String) async throws {
        try await StoreClient.shared.profilesRename(id: id, name: name)
        await refresh()
    }

    /// Deletes a profile: unlists it, closes its stores, and removes its
    /// directory. Drops the cached client and context first, so nothing
    /// app-side keeps serving the removed profile afterwards. Refuses the
    /// last profile, like the core does.
    func deleteProfile(id: String) async throws {
        try await StoreClient.shared.profilesDelete(id: id)
        clients.removeValue(forKey: id)
        contexts.removeValue(forKey: id)
        await refresh()
    }
}
