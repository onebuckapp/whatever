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
import WebKit

/// Decides whether a navigation may proceed inside the web view.
/// Web schemes load in place; anything else (mailto:, tel:, …) is
/// handed to the OS and cancelled in the tab.
enum NavigationPolicy {
    /// The schemes a web view can render itself. Everything else needs another
    /// app. `whtvr` is the retired name of `w` and stays accepted so stored
    /// URLs keep resolving instead of bouncing to the OS.
    static let inPageSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "blob", "w", "whtvr",
    ]

    static func decision(for request: URLRequest) -> WKNavigationActionPolicy {
        guard canLoadInPage(request) else {
            if let url = request.url {
                handOffToSystem(url)
            }
            return .cancel
        }
        return .allow
    }

    /// Whether this request is one a web view can show, without acting on it.
    ///
    /// Split out from `decision(for:)` because callers that only want to know —
    /// a popup asking for a scheme it cannot draw, say — must not also launch
    /// whatever application handles it.
    static func canLoadInPage(_ request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return inPageSchemes.contains(scheme)
    }

    /// Opens `url` in whatever app the system associates with it.
    static func handOffToSystem(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
