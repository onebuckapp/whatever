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
import Combine

/// The app's password vault, decrypted in memory only while unlocked.
///
/// App-wide rather than per window, because passwords are: the manager card
/// and any future caller observe the same instance. The core owns the vault
/// engine (Argon2id + XChaCha20-Poly1305, strength scoring); this store owns
/// the decrypted shape and the lock state, and never implements crypto.
///
/// Writes are optimistic — the local vault changes first, the store follows
/// behind — and a failed write reloads status so the UI heals to the truth
/// instead of drifting. Locking clears the decrypted vault locally whatever
/// the store says; the status refresh afterwards reports the ground truth.
@MainActor
final class PasswordStore: ObservableObject {
    static let shared = PasswordStore()

    enum LockState: Equatable {
        case unknown
        case unset
        case locked
        case unlocked
    }

    enum UnlockResult: Equatable {
        case unlocked
        case wrongPassword
        case failed(String)
    }

    @Published private(set) var lockState: LockState = .unknown
    @Published private(set) var vault = PasswordVault.empty
    @Published private(set) var lastError: String?
    /// The vault's plaintext reminder, shown after repeated wrong passwords
    /// and editable while unlocked. Nil when none was kept.
    @Published private(set) var vaultHint: String?

    private let client: StoreClient

    /// Test seam: when false, mutations change only the in-memory vault and
    /// never touch the store service.
    var persistEnabled = true

    /// `client` defaults to the shared client when nil: spelled this way
    /// rather than `= .shared` so the main-actor-isolated singleton is only
    /// touched from inside the isolated init body.
    init(client: StoreClient? = nil) {
        self.client = client ?? .shared
    }

    // MARK: - Lock state

    /// Test seam: installs a vault without the store service, so model and
    /// layout tests can drive the UI without XPC. Reads as unlocked.
    func replaceVaultForTesting(_ vault: PasswordVault) {
        self.vault = vault
        lockState = .unlocked
        vaultHint = nil
        lastError = nil
    }

    /// Asks the core for the ground truth: unset, locked, or unlocked.
    func refreshStatus() async {
        do {
            let data = try await client.passwordStatus()
            lockState = Self.lockState(from: data)
            if lockState != .unlocked {
                vault = .empty
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Creates the vault with `master` and an optional `hint`, and leaves
    /// it unlocked. `false` means the store refused (too short, a hint
    /// equal to the password, or a vault already exists); the detail is in
    /// `lastError`.
    @discardableResult
    func setup(master: String, hint: String) async -> Bool {
        lastError = nil
        do {
            try await client.passwordSetup(master: master, hint: hint)
            try await reloadVault()
            await refreshHint()
            lockState = .unlocked
            return true
        } catch {
            lastError = error.localizedDescription
            await refreshStatus()
            return false
        }
    }

    /// Opens the vault. `.wrongPassword` is the expected failure and carries
    /// no `lastError`; anything else does.
    func unlock(master: String) async -> UnlockResult {
        lastError = nil
        do {
            try await client.passwordUnlock(master: master)
            try await reloadVault()
            await refreshHint()
            lockState = .unlocked
            return .unlocked
        } catch {
            if storeStatus(of: error) == .wrongPassword {
                await refreshStatus()
                return .wrongPassword
            }
            lastError = error.localizedDescription
            await refreshStatus()
            return .failed(error.localizedDescription)
        }
    }

    /// Locks the vault and clears the decrypted copy, whatever the store
    /// says; the status refresh afterwards reports the ground truth.
    func lock() async {
        do {
            try await client.passwordLock()
            vault = .empty
            vaultHint = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshStatus()
    }

    /// Reloads the plaintext hint. Works locked; nil when none was kept or
    /// the service could not be reached.
    func refreshHint() async {
        guard let data = try? await client.passwordHint(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hint = root["hint"] as? String,
              !hint.isEmpty
        else {
            vaultHint = nil
            return
        }
        vaultHint = hint
    }

    /// Replaces the hint. Requires the vault to be unlocked; fails
    /// otherwise, with the detail in `lastError`.
    @discardableResult
    func setHint(_ hint: String) async -> Bool {
        do {
            try await client.setPasswordHint(hint)
            await refreshHint()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Scores a candidate password through the core's meter. Works locked;
    /// nil means the service could not be reached, not a weak password.
    func strength(of password: String) async -> PasswordStrength? {
        guard let data = try? await client.passwordStrength(password) else { return nil }
        return PasswordStrength.decode(data)
    }

    // MARK: - Reading

    func site(_ id: String) -> VaultSite? {
        vault.sites.first { $0.id == id }
    }

    // MARK: - Mutations

    @discardableResult
    func createSite(name: String, url: String) -> VaultSite {
        let now = Int64(Date().timeIntervalSince1970)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = VaultSite(
            id: UUID().uuidString,
            name: trimmedName.isEmpty
                ? (URL(string: trimmedURL)?.host ?? trimmedURL)
                : trimmedName,
            url: trimmedURL,
            createdAt: now,
            updatedAt: now
        )
        vault.sites.append(site)
        persist()
        return site
    }

    func updateSite(_ id: String, name: String, url: String) {
        guard let index = vault.sites.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        vault.sites[index].name = trimmedName
        vault.sites[index].url = trimmedURL
        vault.sites[index].updatedAt = Int64(Date().timeIntervalSince1970)
        persist()
    }

    func setSiteFavicon(_ id: String, base64: String?) {
        guard let index = vault.sites.firstIndex(where: { $0.id == id }) else { return }
        vault.sites[index].favicon = base64
        vault.sites[index].updatedAt = Int64(Date().timeIntervalSince1970)
        persist()
    }

    func deleteSite(_ id: String) {
        vault.sites.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    func addCredential(to siteID: String, username: String, password: String) -> VaultCredential? {
        guard let index = vault.sites.firstIndex(where: { $0.id == siteID }) else { return nil }
        let credential = VaultCredential(
            id: UUID().uuidString,
            username: username,
            password: password
        )
        vault.sites[index].credentials.append(credential)
        vault.sites[index].updatedAt = Int64(Date().timeIntervalSince1970)
        persist()
        return credential
    }

    func updateCredential(siteID: String, _ id: String, username: String, password: String) {
        guard let siteIndex = vault.sites.firstIndex(where: { $0.id == siteID }),
              let credIndex = vault.sites[siteIndex].credentials.firstIndex(where: { $0.id == id })
        else {
            return
        }
        vault.sites[siteIndex].credentials[credIndex].username = username
        vault.sites[siteIndex].credentials[credIndex].password = password
        vault.sites[siteIndex].updatedAt = Int64(Date().timeIntervalSince1970)
        persist()
    }

    func deleteCredential(siteID: String, _ id: String) {
        guard let siteIndex = vault.sites.firstIndex(where: { $0.id == siteID }) else { return }
        vault.sites[siteIndex].credentials.removeAll { $0.id == id }
        vault.sites[siteIndex].updatedAt = Int64(Date().timeIntervalSince1970)
        persist()
    }

    func removeAll() {
        vault = .empty
        guard persistEnabled else { return }
        Task {
            do {
                try await client.deletePasswordVault()
            } catch {
                lastError = error.localizedDescription
                await refreshStatus()
            }
        }
    }

    // MARK: - Persistence

    private func reloadVault() async throws {
        let data = try await client.passwordVault()
        vault = PasswordVault.decode(data) ?? .empty
    }

    private func persist() {
        guard persistEnabled else { return }
        guard let document = try? JSONEncoder().encode(vault) else { return }
        Task {
            do {
                try await client.setPasswordVault(document)
            } catch {
                lastError = error.localizedDescription
                await refreshStatus()
            }
        }
    }

    private static func lockState(from data: Data) -> LockState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["state"] as? String
        else {
            return .unknown
        }
        switch state {
        case "unset": return .unset
        case "locked": return .locked
        case "unlocked": return .unlocked
        default: return .unknown
        }
    }
}
