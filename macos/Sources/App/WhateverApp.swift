import AppKit
import SwiftUI

/// No SwiftUI window scenes: every browser tab is a programmatic
/// `NSWindow` managed by `BrowserCoordinator`. The standard app menu
/// (About Whatever, Settings, Services, Hide, Quit) comes from the
/// SwiftUI `App` lifecycle automatically.
@main
struct WhateverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            TabCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BrowserCore.initialize()
        BrowserCoordinator.shared.newTab()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Coordinator state is ground truth: the reopen event can race
        // launch and arrive while the first window is still appearing.
        if BrowserCoordinator.shared.windows.isEmpty {
            BrowserCoordinator.shared.newTab()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
