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
import Combine

/// Default-browser state for the General settings pane.
///
/// Reads which app currently handles `https://` links and, on request, claims
/// both web schemes for Whatever. No persistence involved: the system is the
/// source of truth, read fresh every time the pane appears.
@MainActor
final class DefaultBrowserSettings: ObservableObject {
    @Published private(set) var isDefault = false

    private static let schemes = ["http", "https"]
    private static let probeURL = URL(string: "https://example.com/")!

    /// Re-reads the current handler. Called whenever the pane appears, so a
    /// change made in System Settings while the app runs shows up on return.
    func refresh() {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: Self.probeURL) else {
            isDefault = false
            return
        }
        isDefault = Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Claims `http` and `https` for this app, then re-reads. Best effort
    /// per scheme: a failure on one still leaves the other claimed, and the
    /// refresh reports whatever actually stuck.
    func makeDefault() async {
        let appURL = Bundle.main.bundleURL
        for scheme in Self.schemes {
            try? await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme)
        }
        refresh()
    }
}
