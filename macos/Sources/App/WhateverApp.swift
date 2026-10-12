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
    // Observed so a language switch rebuilds the command menus below: menu
    // item titles are `tr()` snapshots, and the revision tick re-renders
    // them live, with no relaunch. The top-level bar titles do not follow
    // on their own — `MenuBarRetitler` re-applies those in AppKit. Stock
    // submenu items (Services, Hide, standard Edit/Window) stay in the
    // system language — only our items, and the bar titles, translate.
    @StateObject private var localization = Localization.shared

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
                Button(tr("About Whatever", ctx: "Menu.App")) {
                    AppDelegate.showAbout()
                }
            }
            // The stock Quit item quits on the first ⌘Q. Ours warns instead:
            // a keyDown arms the two-press confirmation, while a menu click
            // is deliberate pointer input and quits at once. The Dock menu,
            // shutdown, and direct `terminate:` calls never pass through here
            // and keep quitting immediately.
            CommandGroup(replacing: .appTermination) {
                Button(tr("Quit Whatever", ctx: "Menu.App")) {
                    let source: QuitConfirmation.RequestSource =
                        NSApp.currentEvent?.type == .keyDown ? .keyboard : .menu
                    QuitConfirmation.shared.handleQuitRequest(source: source)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button(tr("New Tab", ctx: "Menu.File")) {
                    BrowserCoordinator.shared.newTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                Button(tr("New Window", ctx: "Menu.File")) {
                    BrowserCoordinator.shared.newWindow()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button(tr("New Incognito Window", ctx: "Menu.File")) {
                    BrowserCoordinator.shared.newPrivateWindow()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button(tr("Print…", ctx: "Menu.File")) {
                    BrowserCoordinator.shared.keyController?.presentPrintPreview()
                }
                .keyboardShortcut("p", modifiers: .command)
                // Deliberately no `.disabled` here: this system group is
                // evaluated at launch before `NSApp` exists, so reading the
                // key window crashes. No tab just beeps in the action.
            }
            TabCommands()
            CommandMenu(tr("Find", ctx: "Menu.Find")) {
                Button(tr("Find in Page…", ctx: "Menu.Find")) {
                    BrowserCoordinator.shared.keyController?.showFindBar()
                }
                .keyboardShortcut("f", modifiers: .command)
                Button(tr("Find Next", ctx: "Menu.Find")) {
                    BrowserCoordinator.shared.keyController?.findNext()
                }
                .keyboardShortcut("g", modifiers: .command)
                Button(tr("Find Previous", ctx: "Menu.Find")) {
                    BrowserCoordinator.shared.keyController?.findPrevious()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandMenu(tr("View", ctx: "Menu.View")) {                Button(tr("Reload Page", ctx: "Menu.View")) {
                    BrowserCoordinator.shared.keyController?.reloadPage()
                }
                .keyboardShortcut("r", modifiers: .command)
                Button(tr("Reload From Origin", ctx: "Menu.View")) {
                    BrowserCoordinator.shared.keyController?.reloadPageFromOrigin()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Toggle(
                    tr("Show Bookmarks Bar", ctx: "Menu.View"),
                    isOn: SettingsStore.shared.binding(\.bookmarks.showBar)
                )
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            // After, not replacing: the stock Help menu is just its search
            // field, which stays. Credits gets its own window rather than
            // joining the About panel so it can carry the full list.
            CommandGroup(after: .help) {
                Button(tr("Credits", ctx: "Menu.Help")) {
                    AppDelegate.showCredits()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(tr("Settings\u{2026}", ctx: "Menu.App")) {
                    AppDelegate.presentSettingsOnFrontWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
                Button(tr("Passwords\u{2026}", ctx: "Menu.App")) {
                    AppDelegate.presentPasswordsOnFrontWindow()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

/// Top-level menu-bar titles, retitled live on every language switch.
///
/// SwiftUI rebuilds command-menu *contents* on the revision tick, but the
/// bar titles — ours (`Tab`, `Split`, `Find`, `View`) and the stock AppKit
/// ones (`File`, `Edit`, `Window`, `Help`) — keep the language they were
/// first built in. So the bar is retitled in AppKit directly, the same
/// pattern as the File > Close retitle below. Submenu contents are never
/// touched: Edit and Window keep their stock items, whatever the language.
enum MenuBarRetitler {
    /// A recognized top-level menu.
    enum ID {
        case file, edit, tab, split, find, view, window, help
    }

    /// Non-separator items our Split menu holds. It has no keyboard
    /// shortcuts to recognize it by (see `TabCommands`), so the shape stands
    /// in — everything else is excluded first, and anything not matching
    /// exactly is left alone. Keep in sync with the Split section there.
    private static let splitButtonCount = 6

    /// Which menu `topItem` heads, by language-independent signatures: key
    /// equivalents, actions, and AppKit's own menu pointers survive
    /// translation, titles do not. Returns nil for anything unrecognized
    /// (the app menu, Services, future menus), which stays exactly as is.
    static func classify(_ topItem: NSMenuItem) -> ID? {
        guard let submenu = topItem.submenu else { return nil }
        let items = submenu.items
        // The File menu owns ⌘W (see `retitleSystemCloseItem`).
        if items.contains(where: {
            $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask.contains(.command)
        }) {
            return .file
        }
        // Stock Edit answers copy: — compared by name, since the action is
        // declared on Objective-C NSResponder without a Swift member.
        if items.contains(where: { $0.action.map(NSStringFromSelector) == "copy:" }) {
            return .edit
        }
        if let windowsMenu = NSApp.windowsMenu, submenu === windowsMenu {
            return .window
        }
        // Fallback when AppKit has not (yet) pointed at the menu: the stock
        // Window menu always carries Minimize.
        if items.contains(where: { $0.action == #selector(NSWindow.performMiniaturize(_:)) }) {
            return .window
        }
        if let helpMenu = NSApp.helpMenu, submenu === helpMenu {
            return .help
        }
        // Ours: Tab (⌘L), Find (⌘F), View (⌘R). Lowercased, so ⇧⌘ variants
        // match too; no stock menu uses these letters.
        if items.contains(where: {
            $0.keyEquivalent.lowercased() == "l" && $0.keyEquivalentModifierMask.contains(.command)
        }) {
            return .tab
        }
        if items.contains(where: {
            $0.keyEquivalent.lowercased() == "f" && $0.keyEquivalentModifierMask.contains(.command)
        }) {
            return .find
        }
        if items.contains(where: {
            $0.keyEquivalent.lowercased() == "r" && $0.keyEquivalentModifierMask.contains(.command)
        }) {
            return .view
        }
        // Split last: shortcut-less, so six buttons, only separators besides,
        // and no submenus (Services) — after everything else had its chance.
        let buttons = items.filter { !$0.isSeparatorItem }
        if buttons.count == splitButtonCount,
           items.allSatisfy({ $0.keyEquivalent.isEmpty && $0.submenu == nil })
        {
            return .split
        }
        return nil
    }

    /// The current-language title for a classified menu. Ours reuse the same
    /// snapshots as their `CommandMenu`s; the stock menus gain `Menu.Bar`
    /// titles while their items stay in the system language.
    static func title(for id: ID) -> String {
        switch id {
        case .file: tr("File", ctx: "Menu.Bar")
        case .edit: tr("Edit", ctx: "Menu.Bar")
        case .window: tr("Window", ctx: "Menu.Bar")
        case .help: tr("Help", ctx: "Menu.Bar")
        case .tab: tr("Tab", ctx: "Menu.Tab")
        case .split: tr("Split", ctx: "Menu.Split")
        case .find: tr("Find", ctx: "Menu.Find")
        case .view: tr("View", ctx: "Menu.View")
        }
    }

    /// Retitles every recognized top-level menu, leaving the rest alone.
    static func retitleBar() {
        for topItem in NSApp.mainMenu?.items ?? [] {
            if let id = classify(topItem) {
                topItem.title = title(for: id)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI's own File menu owns ⌘W, and it is labelled "Close", but in this
    /// app it closes the current tab and only closes the window when there is no
    /// tab left. Retitled so the menu says what it does.
    ///
    /// Best effort by design: the behaviour lives in `BrowserWindow.performClose`,
    /// so if SwiftUI ever rebuilds this menu the worst outcome is the old label
    /// coming back rather than ⌘W going back to closing the window. Anything that
    /// had tried to fix this by clearing the item's key equivalent instead would
    /// have that failure the other way round.
    ///
    /// Found by key equivalent rather than by title, so it works whatever the
    /// system language is (our Tab menu deliberately holds no ⌘W, which is
    /// what makes the match unique). The item is kept weakly so a language
    /// switch re-titles it in place instead of searching again.
    private static weak var closeTabItem: NSMenuItem?

    private static func retitleSystemCloseItem() {
        let title = tr("Close Tab", ctx: "Menu.File")
        if let item = closeTabItem {
            item.title = title
            return
        }
        for topItem in NSApp.mainMenu?.items ?? [] {
            guard let items = topItem.submenu?.items else { continue }
            if let close = items.first(where: {
                $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask.contains(.command)
            }) {
                close.title = title
                closeTabItem = close
                return
            }
        }
    }

    /// Opens the standard About panel with Whatever's tagline and
    /// copyright credits. The panel itself stays Apple's — name and
    /// version come from the bundle — only the credits are ours.
    static func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: AboutContent.credits()])
    }

    private static var creditsController: CreditsWindowController?

    /// Retained system-locale observer: a system language change re-resolves
    /// the interface language (when the setting follows the system) without
    /// a relaunch. Block-based observers unregister when the token dies, so
    /// this lives as long as the app does.
    private var localeChangeObserver: NSObjectProtocol?
    /// Same lifetime for the menu retitle observer (see above).
    private var menuRetitleObserver: NSObjectProtocol?

    /// Opens the Credits window, focusing it when already open. Single
    /// instance: the controller is created on first use and held while its
    /// window lives (it nils itself on close).
    @MainActor
    static func showCredits() {
        if creditsController == nil {
            creditsController = CreditsWindowController()
        }
        creditsController?.show()
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
        Self.retitleSystemCloseItem()
        MenuBarRetitler.retitleBar()
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
            // Warms the bookmark cache while the window is still opening, so
            // the address bar's first query already sees bookmarks. Runs with
            // the other launch loads rather than on any keystroke path.
            async let bookmarks = BookmarkStore.shared.prewarm()
            await SettingsStore.shared.load()
            _ = try? await version
            _ = await bookmarks

            // Resolves the interface language (settings override or system
            // locale) and caches the active catalog, so the first migrated
            // screen already reads translated. Fail-open: a failure leaves
            // English, which is what untranslated builds read anyway.
            await Localization.shared.refresh()
            // Follows the system locale for as long as the setting says
            // "system": a language change in System Settings re-resolves
            // without a relaunch.
            localeChangeObserver = NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    await Localization.shared.refresh()
                }
            }
            // SwiftUI rebuilds our command menus itself on the revision tick,
            // but the File > Close retitle above and the top-level bar
            // titles are AppKit-owned: re-apply them on every language
            // switch.
            menuRetitleObserver = NotificationCenter.default.addObserver(
                forName: .localizationDidChange,
                object: nil,
                queue: .main
            ) { _ in
                Self.retitleSystemCloseItem()
                MenuBarRetitler.retitleBar()
            }

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

    /// The Dock's right-click menu. The same three constructors as the File
    /// menu, so they work with no windows open too: New Tab falls back to a
    /// fresh window when there is nothing to add it to, exactly like ⌘T.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newTab = NSMenuItem(
            title: tr("New Tab", ctx: "Menu.Dock"),
            action: #selector(dockNewTab),
            keyEquivalent: ""
        )
        let newWindow = NSMenuItem(
            title: tr("New Window", ctx: "Menu.Dock"),
            action: #selector(dockNewWindow),
            keyEquivalent: ""
        )
        let newPrivateWindow = NSMenuItem(
            title: tr("New Incognito Window", ctx: "Menu.Dock"),
            action: #selector(dockNewPrivateWindow),
            keyEquivalent: ""
        )
        for item in [newTab, newWindow, newPrivateWindow] {
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc @MainActor private func dockNewTab() {
        BrowserCoordinator.shared.newTab()
    }

    @objc @MainActor private func dockNewWindow() {
        BrowserCoordinator.shared.newWindow()
    }

    @objc @MainActor private func dockNewPrivateWindow() {
        BrowserCoordinator.shared.newPrivateWindow()
    }
}
