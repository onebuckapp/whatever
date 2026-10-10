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
import SwiftUI

/// Owns the Credits window: a plain titled window, not a browser window and
/// not an in-window card, so Help > Credits works with no browser window
/// open. Single instance — reopening focuses the existing window — owned by
/// the AppDelegate, outside `BrowserCoordinator` (which only tracks browser
/// windows for sessions and tab cycling).
@MainActor
final class CreditsWindowController {
    private static let contentSize = NSSize(width: 720, height: 520)

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    var isOpen: Bool { window != nil }

    /// Shows the window, focusing it when already open.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        // Background sibling below the content, never its parent, so the
        // scroll position cannot move it.
        let background = CreditsBackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let hosting = NSHostingView(rootView: CreditsContentView())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: content.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        window.title = "Credits"
        window.isReleasedWhenClosed = false
        window.center()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.window = nil
            self?.closeObserver = nil
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Test seam: the live window, if open.
    var windowForTesting: NSWindow? { window }
}
