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

/// Value snapshot of a browser tab. Independent from `WKWebView`,
/// which is owned by the tab's `BrowserWindowController`.
struct BrowserTabState: Identifiable {
    let id: UUID
    var title: String
    var url: URL?
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var estimatedProgress: Double

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        url: URL? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        estimatedProgress: Double = 0
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.estimatedProgress = estimatedProgress
    }
}
