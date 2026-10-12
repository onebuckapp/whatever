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
        CommandMenu(tr("Tab", ctx: "Menu.Tab")) {
            // New Tab, New Window and New Incognito Window live in File (see
            // `WhateverApp`), where people reach for them. They used to be
            // here, but a shortcut cannot be shown in two menus: SwiftUI gives
            // it to whichever comes first and strips the other, like ⌘W below.
            Button(tr("Search History", ctx: "Menu.Tab")) {
                BrowserCoordinator.shared.keyController?.focusAddressBar()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button(tr("Focus Address Bar", ctx: "Menu.Tab")) {
                BrowserCoordinator.shared.keyController?.focusAddressBar()
            }
            .keyboardShortcut("l", modifiers: .command)

            // Deliberately no "Close Tab" item here. Declaring one with ⌘W used to
            // get its key equivalent silently stripped, because SwiftUI gives a
            // duplicate to whichever menu comes first and the File menu's
            // system-provided Close comes before Tab. The item would sit there
            // reachable by click but showing no shortcut, next to the ⌘W that
            // really closes the tab. `BrowserWindow.performClose` is where ⌘W is
            // handled, and `AppDelegate` renames that File item to match.

            Button(tr("Reopen Closed Tab", ctx: "Menu.Tab")) {
                BrowserCoordinator.shared.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button(tr("Move Tab to New Window", ctx: "Menu.Tab")) {
                guard let tab = BrowserCoordinator.shared.keyController?.selectedTab else { return }
                BrowserCoordinator.shared.newWindow(containing: tab)
            }

            Divider()

            Button(tr("Show Previous Tab", ctx: "Menu.Tab")) {
                BrowserCoordinator.shared.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button(tr("Show Next Tab", ctx: "Menu.Tab")) {
                BrowserCoordinator.shared.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()

            ForEach(1..<10) { number in
                Button(tr("Select Tab {n}", ctx: "Menu.Tab", args: ["n": "\(number)"])) {
                    BrowserCoordinator.shared.selectTab(at: number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }

        CommandMenu(tr("Split", ctx: "Menu.Split")) {
            Button(tr("Split with Next Tab", ctx: "Menu.Split")) {
                BrowserCoordinator.shared.keyController?.splitWithNextTab()
            }

            Button(tr("Split with Previous Tab", ctx: "Menu.Split")) {
                BrowserCoordinator.shared.keyController?.splitWithPreviousTab()
            }

            Divider()

            Button(tr("Focus Next Pane", ctx: "Menu.Split")) {
                BrowserCoordinator.shared.keyController?.focusNextPane()
            }

            Button(tr("Focus Previous Pane", ctx: "Menu.Split")) {
                BrowserCoordinator.shared.keyController?.focusPreviousPane()
            }

            Button(tr("Collapse Split", ctx: "Menu.Split")) {
                BrowserCoordinator.shared.keyController?.collapseSplit()
            }
            .disabled(BrowserCoordinator.shared.keyController?.isSplit != true)

            Divider()

            Button(tr("Close Pane", ctx: "Menu.Split")) {
                guard let controller = BrowserCoordinator.shared.keyController,
                      let tab = controller.selectedTab
                else { return }
                controller.closePane(tab)
            }
            .disabled(BrowserCoordinator.shared.keyController?.isSplit != true)
        }
    }
}
