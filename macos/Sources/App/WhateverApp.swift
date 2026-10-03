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
            TabCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    AppDelegate.presentSettingsOnFrontWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One subscription, so a web setting changed anywhere — a settings
        // control, a migration, a future programmatic caller — reaches open
        // pages the same way.
        SettingsStore.shared.onChange = { changed in
            guard changed.contains("web") else { return }
            BrowserCoordinator.shared.applyLiveWebSettings()
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
