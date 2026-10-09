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

/// Owns the session document: writes it to the store on a debounce after any
/// change, and reads it back at launch.
///
/// Deliberately not `@MainActor` or an `ObservableObject`. Nothing here is
/// published and nothing here touches the window model; `BrowserCoordinator`
/// builds a `SessionSnapshot` from the windows it already owns and hands it
/// over. That keeps the document format and the window model from having to know
/// about each other.
actor SessionStore {
    static let shared = SessionStore()

    /// How long to wait after a change before writing.
    ///
    /// A page load is the common trigger and each one would otherwise rewrite
    /// the whole document, so this coalesces a burst of them. Short enough that
    /// a crash costs about a second of typing, not a session.
    private static let saveDebounce: Duration = .seconds(1)

    /// Upper bound on a single write.
    ///
    /// This runs on the quit path through `saveNow`, and a store service that has
    /// gone away must not leave the app unable to quit.
    private static let saveTimeout: Duration = .seconds(3)

    private var saveTask: Task<Void, Never>?

    /// Whether a change has not reached the store yet.
    ///
    /// The quit path reads this to decide whether it needs to delay termination
    /// at all, so an unchanged quit does not wait on a round trip.
    private(set) var hasPendingWrite = false

    /// Why the last write failed, for diagnosis. A session that will not save is
    /// worth noticing; losing it silently is how a user's tabs go missing.
    private(set) var lastError: String?

    private init() {}

    // MARK: - Loading

    /// Reads the stored snapshot, or nil when there is nothing restorable.
    ///
    /// A store that cannot be reached is not fatal: the caller opens a fresh
    /// window instead, exactly as a first launch does.
    func load() async -> SessionSnapshot? {
        do {
            let data = try await StoreClient.shared.session()
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            return snapshot.isRestorable ? snapshot : nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Writing

    /// Schedules a write, replacing any one already waiting.
    func scheduleSave(_ snapshot: SessionSnapshot) {
        saveTask?.cancel()
        hasPendingWrite = true
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            await self?.saveNow(snapshot)
        }
    }

    /// Writes immediately, bypassing the debounce. Used on quit and when a
    /// window closes, where there may be no later chance.
    func saveNow(_ snapshot: SessionSnapshot) async {
        saveTask?.cancel()
        saveTask = nil
        hasPendingWrite = false

        let didSave = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await StoreClient.shared.saveSession(
                        JSONEncoder().encode(snapshot)
                    )
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.saveTimeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        lastError = didSave ? nil : (lastError ?? "session save timed out")
    }

    /// Forgets the stored snapshot, so the next launch opens a fresh session.
    func clear() async {
        saveTask?.cancel()
        saveTask = nil
        hasPendingWrite = false
        do {
            try await StoreClient.shared.clearSession()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}