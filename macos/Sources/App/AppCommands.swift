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

            Button("Focus Address Bar") {
                BrowserCoordinator.shared.keyController?.focusAddressBar()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("New Window") {
                BrowserCoordinator.shared.newWindow()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Close Tab") {
                BrowserCoordinator.shared.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)

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
