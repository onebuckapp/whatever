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
import Testing
@testable import Whatever

/// Top-level menu-bar retitling: classification by language-independent
/// signatures (titles do not survive translation), title resolution through
/// the string table, and the end-to-end bar walk on a synthetic main menu.
/// Submenu contents are never touched — only the bar titles move.
@MainActor
struct MenuBarRetitleTests {
    private func topItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for item in items {
            submenu.addItem(item)
        }
        top.submenu = submenu
        return top
    }

    private func keyItem(_ key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: "item", action: nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func actionItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "item", action: action, keyEquivalent: "")
    }

    private func plainItem() -> NSMenuItem {
        NSMenuItem(title: "item", action: nil, keyEquivalent: "")
    }

    @Test("the file menu is recognized by its close item")
    func fileByCloseItem() {
        let file = topItem(title: "File", items: [keyItem("t"), keyItem("w")])
        #expect(MenuBarRetitler.classify(file) == .file)
    }

    @Test("the edit menu is recognized by its copy action")
    func editByCopyAction() {
        let edit = topItem(title: "Edit", items: [
            actionItem(NSSelectorFromString("copy:")),
            actionItem(NSSelectorFromString("paste:")),
        ])
        #expect(MenuBarRetitler.classify(edit) == .edit)
    }

    @Test("tab, find and view are recognized by their shortcuts")
    func oursByShortcut() {
        #expect(MenuBarRetitler.classify(topItem(title: "Tab", items: [keyItem("l")])) == .tab)
        #expect(MenuBarRetitler.classify(topItem(title: "Find", items: [keyItem("f")])) == .find)
        #expect(MenuBarRetitler.classify(topItem(title: "View", items: [keyItem("r")])) == .view)
    }

    @Test("shift-letter shortcuts still classify")
    func shiftShortcutClassifies() {
        let tab = topItem(title: "Tab", items: [keyItem("L", modifiers: [.command, .shift])])
        #expect(MenuBarRetitler.classify(tab) == .tab)
    }

    @Test("the split menu is recognized by shape: six buttons, no shortcuts")
    func splitByShape() {
        let split = topItem(
            title: "Split",
            items: [
                plainItem(), plainItem(), NSMenuItem.separator(),
                plainItem(), plainItem(), plainItem(), NSMenuItem.separator(),
                plainItem(),
            ]
        )
        #expect(MenuBarRetitler.classify(split) == .split)
    }

    @Test("a shortcut-less menu of the wrong size stays unrecognized")
    func wrongSizeUnrecognized() {
        let other = topItem(title: "Other", items: [plainItem(), plainItem(), plainItem()])
        #expect(MenuBarRetitler.classify(other) == nil)
    }

    @Test("a split-shaped menu with a shortcut stays unrecognized")
    func shortcutSplitShapeUnrecognized() {
        let other = topItem(
            title: "Other",
            items: [plainItem(), plainItem(), plainItem(), plainItem(), plainItem(), keyItem("x")]
        )
        #expect(MenuBarRetitler.classify(other) == nil)
    }

    @Test("a menu holding a submenu stays unrecognized")
    func submenuHolderUnrecognized() {
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        let app = topItem(title: "Whatever", items: [plainItem(), services])
        #expect(MenuBarRetitler.classify(app) == nil)
    }

    @Test("a top item without a submenu stays unrecognized")
    func bareTopItemUnrecognized() {
        let bare = NSMenuItem(title: "Bare", action: nil, keyEquivalent: "")
        #expect(MenuBarRetitler.classify(bare) == nil)
    }

    @Test("window resolves by minimize action, help through AppKit's pointer")
    func windowAndHelp() {
        let window = topItem(title: "Window", items: [actionItem(#selector(NSWindow.performMiniaturize(_:)))])
        #expect(MenuBarRetitler.classify(window) == .window)
        let helpMenu = NSMenu(title: "Help")
        let previousHelp = NSApp.helpMenu
        NSApp.helpMenu = helpMenu
        defer { NSApp.helpMenu = previousHelp }
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        help.submenu = helpMenu
        #expect(MenuBarRetitler.classify(help) == .help)
    }

    @Test("titles resolve through the table, missing ones fall back")
    func titlesResolve() {
        Localization.shared.load(table: LocaleTable(
            lang: "ro",
            strings: [
                "Menu.Bar\u{04}File": "Fișier",
                "Menu.Tab\u{04}Tab": "Filă",
            ]
        ))
        defer { Localization.shared.load(table: LocaleTable(lang: "en", strings: [:])) }
        #expect(MenuBarRetitler.title(for: .file) == "Fișier")
        #expect(MenuBarRetitler.title(for: .tab) == "Filă")
        #expect(MenuBarRetitler.title(for: .help) == "Help")
    }

    @Test("the bar walk retitles recognized menus and leaves the rest")
    func barWalkRetitles() {
        Localization.shared.load(table: LocaleTable(
            lang: "ro",
            strings: [
                "Menu.Bar\u{04}File": "Fișier",
                "Menu.Bar\u{04}Edit": "Editare",
                "Menu.Tab\u{04}Tab": "Filă",
            ]
        ))
        defer { Localization.shared.load(table: LocaleTable(lang: "en", strings: [:])) }
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let file = topItem(title: "File", items: [keyItem("w")])
        let edit = topItem(title: "Edit", items: [actionItem(NSSelectorFromString("copy:"))])
        let tab = topItem(title: "Tab", items: [keyItem("l")])
        let app = topItem(title: "Whatever", items: [plainItem()])
        let bar = NSMenu(title: "MainMenu")
        for item in [app, file, edit, tab] {
            bar.addItem(item)
        }
        NSApp.mainMenu = bar
        MenuBarRetitler.retitleBar()
        #expect(file.title == "Fișier")
        #expect(edit.title == "Editare")
        #expect(tab.title == "Filă")
        #expect(app.title == "Whatever")
    }
}
