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

/// Tab and split commands. The standard app menu (About, Settings,
/// Hide, Quit) comes from the SwiftUI `App` lifecycle.
struct TabCommands: Commands {
    var body: some Commands {
        CommandMenu("Tab") {
            Button("New Tab") {
                BrowserCoordinator.shared.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Search History") {
                BrowserCoordinator.shared.keyController?.focusAddressBar()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Focus Address Bar") {
                BrowserCoordinator.shared.keyController?.focusAddressBar()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("New Window") {
                BrowserCoordinator.shared.newWindow()
            }
            .keyboardShortcut("n", modifiers: .command)

            // Deliberately no "Close Tab" item here. Declaring one with ⌘W used to
            // get its key equivalent silently stripped, because SwiftUI gives a
            // duplicate to whichever menu comes first and the File menu's
            // system-provided Close comes before Tab. The item would sit there
            // reachable by click but showing no shortcut, next to the ⌘W that
            // really closes the tab. `BrowserWindow.performClose` is where ⌘W is
            // handled, and `AppDelegate` renames that File item to match.

            Button("Reopen Closed Tab") {
                BrowserCoordinator.shared.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("Move Tab to New Window") {
                guard let tab = BrowserCoordinator.shared.keyController?.selectedTab else { return }
                BrowserCoordinator.shared.newWindow(containing: tab)
            }

            Divider()

            Button("Show Previous Tab") {
                BrowserCoordinator.shared.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Show Next Tab") {
                BrowserCoordinator.shared.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()

            ForEach(1..<10) { number in
                Button("Select Tab \(number)") {
                    BrowserCoordinator.shared.selectTab(at: number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }

        CommandMenu("Split") {
            Button("Split with Next Tab") {
                BrowserCoordinator.shared.keyController?.splitWithNextTab()
            }

            Button("Split with Previous Tab") {
                BrowserCoordinator.shared.keyController?.splitWithPreviousTab()
            }

            Divider()

            Button("Focus Next Pane") {
                BrowserCoordinator.shared.keyController?.focusNextPane()
            }

            Button("Focus Previous Pane") {
                BrowserCoordinator.shared.keyController?.focusPreviousPane()
            }

            Button("Collapse Split") {
                BrowserCoordinator.shared.keyController?.collapseSplit()
            }
            .disabled(BrowserCoordinator.shared.keyController?.isSplit != true)

            Divider()

            Button("Close Pane") {
                guard let controller = BrowserCoordinator.shared.keyController,
                      let tab = controller.selectedTab
                else { return }
                controller.closePane(tab)
            }
            .disabled(BrowserCoordinator.shared.keyController?.isSplit != true)
        }
    }
}
