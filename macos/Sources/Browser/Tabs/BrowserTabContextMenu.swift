import AppKit

/// Identifies a tab context-menu command. Strings are stored on the
/// menu items so items stay independent of the menu's target lifetime.
enum TabMenuAction: String {
    case newTab
    case duplicateTab
    case moveTabToNewWindow
    case togglePin
    case splitWithNextTab
    case splitWithPreviousTab
    case closePane
    case focusNextPane
    case focusPreviousPane
    case reloadTab
    case openInNewWindow
    case copyURL
    case qrCode
    case settings
    case closeTab
    case closeOtherTabs
    case closeTabsToTheRight
}

/// Retained by the window controller so `NSMenuItem`'s weak target stays
/// alive while a menu is on screen.
@MainActor
final class TabMenuTarget: NSObject {
    private weak var controller: BrowserWindowController?
    private weak var tab: BrowserTab?

    init(controller: BrowserWindowController, tab: BrowserTab) {
        self.controller = controller
        self.tab = tab
    }

    func rebind(tab: BrowserTab) {
        self.tab = tab
    }

    /// Handles a drag that finished outside every browser window: the
    /// tab becomes a window of its own.
    func tabDidEndDragOutsideApp(tab: BrowserTab, at screenPoint: NSPoint) {
        guard let controller else { return }
        BrowserCoordinator.shared.detach(
            tab: tab,
            from: controller,
            atScreenPoint: screenPoint
        )
    }

    /// Named to avoid `NSObject.perform(_:)`: a method literally called
    /// `perform` collides with the inherited selector-based API, and
    /// `#selector` then resolves to NSObject's implementation instead of
    /// this handler, silently breaking every tab-menu item.
    @objc func handleMenuItem(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String,
              let command = TabMenuAction(rawValue: action),
              let controller,
              let tab
        else {
            return
        }
        BrowserTabContextMenu.perform(command, tab: tab, controller: controller)
    }
}

/// Builds the dynamic right-click menu for a tab in the custom tab bar.
@MainActor
enum BrowserTabContextMenu {
    static func menu(
        for tab: BrowserTab,
        controller: BrowserWindowController
    ) -> NSMenu {
        let target = controller.tabMenuTarget(for: tab)
        let menu = NSMenu()

        add("New Tab", .newTab, to: menu, target: target)
        add("Duplicate Tab", .duplicateTab, to: menu, target: target)
        add("Move Tab to New Window", .moveTabToNewWindow, to: menu, target: target)
        add(tab.presentation.isPinned ? "Unpin Tab" : "Pin Tab", .togglePin, to: menu, target: target)

        menu.addItem(.separator())

        add("Split with Next Tab", .splitWithNextTab, to: menu, target: target)
        if controller.displayedTabs.count > 1 {
            add("Split with Previous Tab", .splitWithPreviousTab, to: menu, target: target)
            add("Close Pane", .closePane, to: menu, target: target)
            add("Focus Next Pane", .focusNextPane, to: menu, target: target)
            add("Focus Previous Pane", .focusPreviousPane, to: menu, target: target)
        }

        menu.addItem(.separator())

        add("Reload Tab", .reloadTab, to: menu, target: target)
        add("Open in New Window", .openInNewWindow, to: menu, target: target)
        add("Copy URL", .copyURL, to: menu, target: target)
        add("Generate QR Code", .qrCode, to: menu, target: target)

        menu.addItem(.separator())

        add("Close Tab", .closeTab, to: menu, target: target)
        add("Close Other Tabs", .closeOtherTabs, to: menu, target: target)
        add("Close Tabs to the Right", .closeTabsToTheRight, to: menu, target: target)

        menu.addItem(.separator())

        add("Settings\u{2026}", .settings, to: menu, target: target)

        return menu
    }

    /// Menu for the toolbar's page button. Same command set as the tab's
/// context menu, minus the pane-only entries that need a split.
    @MainActor
    static func pageMenu(
        for tab: BrowserTab,
        controller: BrowserWindowController
    ) -> NSMenu {
        let target = controller.tabMenuTarget(for: tab)
        let menu = NSMenu()

        add("New Tab", .newTab, to: menu, target: target)
        add("Duplicate Tab", .duplicateTab, to: menu, target: target)
        add("Move Tab to New Window", .moveTabToNewWindow, to: menu, target: target)
        add(tab.presentation.isPinned ? "Unpin Tab" : "Pin Tab", .togglePin, to: menu, target: target)

        menu.addItem(.separator())

        add("Split with Next Tab", .splitWithNextTab, to: menu, target: target)
        add("Split with Previous Tab", .splitWithPreviousTab, to: menu, target: target)

        menu.addItem(.separator())

        add("Reload Tab", .reloadTab, to: menu, target: target)
        add("Copy URL", .copyURL, to: menu, target: target)
        add("Generate QR Code", .qrCode, to: menu, target: target)

        menu.addItem(.separator())

        add("Close Tab", .closeTab, to: menu, target: target)
        add("Close Other Tabs", .closeOtherTabs, to: menu, target: target)
        add("Close Tabs to the Right", .closeTabsToTheRight, to: menu, target: target)

        menu.addItem(.separator())

        add("Settings\u{2026}", .settings, to: menu, target: target)

        return menu
    }

    @MainActor
    static func perform(
        _ command: TabMenuAction,
        tab: BrowserTab,
        controller: BrowserWindowController
    ) {
        let coordinator = BrowserCoordinator.shared
        switch command {
        case .newTab:
            coordinator.newTab(url: nil, in: controller)
        case .duplicateTab:
            controller.duplicateTab(tab)
        case .moveTabToNewWindow:
            controller.detachTab(tab)
            coordinator.newWindow(containing: tab)
        case .togglePin:
            tab.presentation.isPinned.toggle()
            controller.refresh()
        case .splitWithNextTab:
            controller.splitWithNextTab()
        case .splitWithPreviousTab:
            controller.splitWithPreviousTab()
        case .closePane:
            controller.closePane(tab)
        case .focusNextPane:
            controller.focusNextPane()
        case .focusPreviousPane:
            controller.focusPreviousPane()
        case .reloadTab:
            tab.tabController.reload()
        case .openInNewWindow:
            coordinator.newWindow(containing: tab)
        case .copyURL:
            // `displayURL` so the copy is the tab's address even if the tab has
            // no realized view yet.
            let url = tab.displayURL
            if !url.isAddresslessPage {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        case .qrCode:
            controller.presentQRCode(for: tab)
        case .settings:
            controller.presentSettings()
        case .closeTab:
            controller.closeTab(tab)
        case .closeOtherTabs:
            controller.closeOtherTabs(except: tab)
        case .closeTabsToTheRight:
            controller.closeTabs(toTheRightOf: tab)
        }
    }

    private static func add(
        _ title: String,
        _ command: TabMenuAction,
        to menu: NSMenu,
        target: TabMenuTarget
    ) {
        let item = NSMenuItem(title: title, action: #selector(TabMenuTarget.handleMenuItem(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = command.rawValue
        menu.addItem(item)
    }
}
