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

/// No SwiftUI window scenes: every browser tab is a programmatic
/// `NSWindow` managed by `BrowserCoordinator`. The standard app menu
/// (About Whatever, Settings, Services, Hide, Quit) comes from the
/// SwiftUI `App` lifecycle automatically.
@main
struct WhateverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No `Settings` scene. Declaring one opens a blank window instead of
        // Whatever's own modal, and the app menu's Settings item is what most
        // people reach for. `.commands` replaces it with an item that opens the
        // real thing on the front window.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Whatever") {
                    AppDelegate.showAbout()
                }
            }
            CommandGroup(replacing: .newItem) {
                Divider()
                Button("Print…") {
                    BrowserCoordinator.shared.keyController?.presentPrintPreview()
                }
                .keyboardShortcut("p", modifiers: .command)
                // Deliberately no `.disabled` here: this system group is
                // evaluated at launch before `NSApp` exists, so reading the
                // key window crashes. No tab just beeps in the action.
            }
            TabCommands()
            CommandMenu("Find") {
                Button("Find in Page…") {
                    BrowserCoordinator.shared.keyController?.showFindBar()
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") {
                    BrowserCoordinator.shared.keyController?.findNext()
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") {
                    BrowserCoordinator.shared.keyController?.findPrevious()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                Button("Reload Page") {
                    BrowserCoordinator.shared.keyController?.reloadPage()
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Reload From Origin") {
                    BrowserCoordinator.shared.keyController?.reloadPageFromOrigin()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Toggle(
                    "Show Bookmarks Bar",
                    isOn: SettingsStore.shared.binding(\.bookmarks.showBar)
                )
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    AppDelegate.presentSettingsOnFrontWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
                Button("Passwords\u{2026}") {
                    AppDelegate.presentPasswordsOnFrontWindow()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI's own File menu owns ⌘W, and it is labelled "Close", but in this
    /// app it closes the current tab and only closes the window when there is no
    /// tab left. Renamed so the menu says what it does.
    ///
    /// Best effort by design: the behaviour lives in `BrowserWindow.performClose`,
    /// so if SwiftUI ever rebuilds this menu the worst outcome is the old label
    /// coming back rather than ⌘W going back to closing the window. Anything that
    /// had tried to fix this by clearing the item's key equivalent instead would
    /// have that failure the other way round.
    private static func renameSystemCloseItemToCloseTab() {
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" }),
              let item = fileMenu.submenu?.items.first(where: { $0.title == "Close" })
        else { return }
        item.title = "Close Tab"
    }

    /// Opens the standard About panel with Whatever's tagline and
    /// copyright credits. The panel itself stays Apple's — name and
    /// version come from the bundle — only the credits are ours.
    static func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: AboutContent.credits()])
    }

    /// Opens the settings modal on whichever browser window is frontmost.
    ///
    /// Falls back to the first window, and opens a window if there are none, so
    /// the app menu's Settings item always does something instead of quietly
    /// doing nothing.
    @MainActor
    static func presentSettingsOnFrontWindow() {
        let windows = BrowserCoordinator.shared.windows
        guard let target = windows.first(where: { $0.window?.isKeyWindow == true })
            ?? windows.first
        else {
            BrowserCoordinator.shared.newTab()
            return
        }
        target.presentSettings()
    }

    /// Opens the password manager on whichever browser window is frontmost.
    /// Same fallback chain as settings: frontmost, first, else a new window.
    @MainActor
    static func presentPasswordsOnFrontWindow() {
        let windows = BrowserCoordinator.shared.windows
        guard let target = windows.first(where: { $0.window?.isKeyWindow == true })
            ?? windows.first
        else {
            BrowserCoordinator.shared.newTab()
            return
        }
        target.presentPasswordManager()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.renameSystemCloseItemToCloseTab()
        // Idle-tab reaping runs for the life of the app once started.
        TabSleeper.shared.start()
        // One subscription, so a web setting changed anywhere — a settings
        // control, a migration, a future programmatic caller — reaches open
        // pages the same way.
        SettingsStore.shared.onChange = { changed in
            if changed.contains("web") {
                BrowserCoordinator.shared.applyLiveWebSettings()
                // The sleep threshold lives in the same section: enabling it
                // reaps at once instead of waiting for the next minute.
                TabSleeper.shared.sweep()
            }
            if changed.contains("appearance") {
                BrowserCoordinator.shared.applyLiveBackgroundSettings()
            }
            if changed.contains("search") {
                BrowserCoordinator.shared.applyLiveSearchLinkGuard()
            }
            if changed.contains("adblock") {
                BrowserCoordinator.shared.applyLiveContentBlocker()
            }
        }
        Task { @MainActor in
            // The core lives in the WhateverStore XPC service, which launchd
            // starts on this first connection. Loading settings warms it and
            // brings the user's saved values into the app. A failure here is
            // not fatal: the browser still opens with defaults, it just cannot
            // read or write stored data.
            async let version = BrowserCore.version()
            async let session = SessionStore.shared.load()
            await SettingsStore.shared.load()
            _ = try? await version

            // Compiles the content-blocker lists before the first tab opens,
            // so the first page is already filtered. Fail-open: a failure
            // leaves the store empty and pages load unblocked.
            await ContentBlockerStore.shared.refreshIfNeeded()

            // Reopen the session the user left, and only fall back to a fresh
            // window when there was nothing to reopen. The two stores are read
            // concurrently: neither depends on the other, and the session load
            // is what decides whether this launch opens anything at all.
            if BrowserCoordinator.shared.restore(from: await session) == 0 {
                BrowserCoordinator.shared.newTab()
            }
        }
    }

    /// Lets a pending write finish before the process goes away.
    ///
    /// Deliberately not `applicationWillTerminate`: the store lives in another
    /// process, so saving is `async`, and blocking the main thread on a
    /// semaphore would starve the main actor that the save itself needs to run
    /// on. The save would then never happen and the wait would always run out.
    /// `terminateLater` keeps the run loop turning instead, which is what lets
    /// the write complete.
    ///
    /// The session is written on every quit, not only when one is pending. A
    /// quit is the one moment the user's last few seconds of navigation are
    /// guaranteed to have somewhere to go, and unlike settings a session is not
    /// recoverable from anywhere else.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let settingsPending = SettingsStore.shared.hasPendingWrite
            let sessionPending = await BrowserCoordinator.shared.hasPendingSessionWrite()
            guard settingsPending || sessionPending else {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
                return
            }
            if settingsPending {
                await SettingsStore.shared.saveNow()
            }
            if sessionPending {
                await BrowserCoordinator.shared.saveSessionNow()
            }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opens addresses the system routes to the app: default-browser clicks
    /// and `open <url>`. One tab per address in the key window (or a fresh
    /// window when there is none), without grabbing the address bar — the
    /// page is already where the user is going.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                BrowserCoordinator.shared.newTab(url: url, focusesAddressBar: false)
            }
        }
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
