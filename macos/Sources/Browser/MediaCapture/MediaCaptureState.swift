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

/// What a tab's page is doing with the camera and microphone.
///
/// WebKit offers no handle on a running capture, so this tracks verdicts,
/// not sessions: `requests` await the user's answer in the toolbar popup,
/// `grants` were allowed and are assumed live until the page goes away.
/// A grant that already ended reads as live until the next navigation —
/// that over-reporting is the honest limit of the public API, and the
/// popup says reloads revoke.
///
/// Screen sharing never appears here: on macOS it never reaches the host
/// app (the system picker answers per share).
struct MediaCaptureState: Equatable {
    /// Kinds the page was allowed and may still hold.
    var grants: Set<AppSettings.MediaCaptureKind> = []
    /// Kinds the page asked for and nobody has answered yet.
    var requests: Set<AppSettings.MediaCaptureKind> = []

    /// Whether the toolbar shows the capture button for this tab.
    var hasActivity: Bool {
        !grants.isEmpty || !requests.isEmpty
    }

    /// Notes a request awaiting verdict.
    mutating func noteRequest(_ kind: AppSettings.MediaCaptureKind) {
        requests.insert(kind)
    }

    /// Notes a granted request: it leaves `requests` and joins `grants`.
    mutating func noteGranted(_ kind: AppSettings.MediaCaptureKind) {
        requests.remove(kind)
        grants.insert(kind)
    }

    /// Drops a request answered with denial.
    mutating func noteDenied(_ kind: AppSettings.MediaCaptureKind) {
        requests.remove(kind)
    }

    /// Clears everything: the owning page is gone.
    mutating func clear() {
        grants = []
        requests = []
    }

    /// State carried across a navigation: same host keeps its grants (a
    /// same-document walk does not kill tracks), a new host or no host
    /// drops everything, and pending requests never survive the move.
    static func carried(from oldHost: String?, to newHost: String?, state: MediaCaptureState) -> MediaCaptureState {
        guard let oldHost, let newHost, oldHost == newHost else {
            return MediaCaptureState()
        }
        var carried = state
        carried.requests = []
        return carried
    }
}
