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

/// A tab's back/forward URL list and position, as pure value semantics.
///
/// Every mutation goes through here so the rules live in one place and are
/// unit-testable:
///
/// - A new address always appends and drops forward entries. Nothing here
///   collapses repeats: each access is logged, and fluent prev/next
///   navigation is a direct consequence of the list being complete.
/// - Movement only shifts the index; the list itself never changes.
/// - `noteCommitted` reconciles addresses the page committed to without going
///   through `navigate(to:)` (scripted, form, and redirect navigations), so
///   the list cannot disagree with what is on screen.
/// - `drop` removes click trackers Nim declined to register, fixing the
///   index, so Back skips them.
struct TabHistory: Equatable {
    private(set) var urls: [URL] = []
    private(set) var index: Int = -1

    init(urls: [URL] = [], index: Int = -1) {
        self.urls = urls
        // Clamp like a restore does: an index past the end settles on the
        // last entry rather than pointing at nothing.
        self.index = urls.isEmpty ? -1 : min(max(0, index), urls.count - 1)
    }

    /// The address the tab is on, or nil when the list is empty.
    var currentURL: URL? {
        guard urls.indices.contains(index) else { return nil }
        return urls[index]
    }

    var canGoBack: Bool {
        index > 0
    }

    var canGoForward: Bool {
        index >= 0 && index < urls.count - 1
    }

    /// Records a new address, dropping any forward entries.
    mutating func navigate(to url: URL) {
        if index < urls.count - 1 {
            urls.removeSubrange((index + 1)..<urls.count)
        }
        urls.append(url)
        index = urls.count - 1
    }

    /// Steps back, returning the address now current, or nil at the start.
    mutating func moveBack() -> URL? {
        guard index > 0 else { return nil }
        index -= 1
        return urls[index]
    }

    /// Steps forward, returning the address now current, or nil at the end.
    mutating func moveForward() -> URL? {
        guard index >= 0, index < urls.count - 1 else { return nil }
        index += 1
        return urls[index]
    }

    /// Drops the entry matching `url`, fixing the index. Returns whether
    /// anything changed. Used when Nim reports the entry is a click tracker
    /// that should never have registered: the tracker's page may still be
    /// showing, and its bounce to the destination records normally when it
    /// commits. A missing entry means the user already moved on — nothing
    /// to do.
    @discardableResult
    mutating func drop(_ url: URL) -> Bool {
        guard let at = urls.firstIndex(where: { url.hasSameAddress(as: $0) }) else { return false }
        urls.remove(at: at)
        if urls.isEmpty {
            index = -1
        } else {
            if at <= index { index -= 1 }
            index = min(index, urls.count - 1)
        }
        return true
    }

    /// Logs a committed address that bypassed `navigate(to:)`.
    ///
    /// Returns whether the list changed. A match against the current
    /// address (see `URL.hasSameAddress`) is a no-op, so reloads and
    /// back/forward loads — which move the index before loading — never
    /// duplicate. `about:blank` never records: it is the teardown address a
    /// dying view is pointed at, not a visit, and Back must never land on it.
    @discardableResult
    mutating func noteCommitted(_ url: URL) -> Bool {
        guard url.absoluteString != "about:blank" else { return false }
        if let current = currentURL, url.hasSameAddress(as: current) {
            return false
        }
        if index < urls.count - 1 {
            urls.removeSubrange((index + 1)..<urls.count)
        }
        urls.append(url)
        index = urls.count - 1
        return true
    }
}
