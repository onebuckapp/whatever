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

import Combine
import Foundation

/// Session "seen" state behind the Downloads button badge.
///
/// Counts downloads that finished while the popup stayed closed. In-memory
/// only: a new launch starts clean, which is exactly the current-session
/// semantics the badge promises, with no migration and nothing to persist.
/// Shared across windows, so opening the popup anywhere clears every badge.
@MainActor
final class DownloadsBadgeCenter: ObservableObject {
    static let shared = DownloadsBadgeCenter()

    /// Finished-but-unseen downloads this session. Zero hides the badge.
    @Published private(set) var unseenCount = 0

    private var unseenIDs = Set<String>()

    /// Records a finished download as unseen. Failed and cancelled rows do
    /// not badge: they surface through retry inside the popup instead.
    func noteFinished(id: String) {
        if unseenIDs.insert(id).inserted {
            unseenCount = unseenIDs.count
        }
    }

    /// Clears the badge. Called when the popup opens.
    func markAllSeen() {
        unseenIDs.removeAll()
        unseenCount = 0
    }
}
