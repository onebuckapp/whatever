import AppKit
import WebKit

/// What it takes to reopen a closed tab. Reopening loads the URL into a
/// fresh tab, so the closed tab's `WKWebView` is released on close
/// instead of staying alive on the reopen stack. Back/forward history,
/// scroll position, and page state do not survive a close/reopen cycle.
struct ClosedTab {
    let url: URL?
    let privacyMode: BrowserPrivacyMode
}

/// Creates, tracks and closes browser windows. Each window owns its
/// tabs; a tab moves between windows by being detached from one and
/// inserted into another, never recreated. Closing a window closes its
/// tabs and records them for "Reopen Closed Tab".
@MainActor
final class BrowserCoordinator: NSObject, ObservableObject {
    static let shared = BrowserCoordinator()

    let history: HistoryRecording = InMemoryHistoryRecorder()

    private(set) var windows: [BrowserWindowController] = []
    private(set) var recentlyClosed: [ClosedTab] = []
    private let maxRecentlyClosed = 25
    private var closeObserver: NSObjectProtocol?

    private override init() {
        super.init()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            // The observer is registered on the main queue.
            MainActor.assumeIsolated {
                self?.windowWillClose(window)
            }
        }
    }

    // MARK: - Windows

    @discardableResult
    func newWindow(url: URL? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(
            initialURL: url,
            history: history
        )
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// Moves a tab into a brand new window, keeping its web view.
    @discardableResult
    func newWindow(
        containing tab: BrowserTab,
        atScreenPoint point: NSPoint? = nil
    ) -> BrowserWindowController {
        let controller = BrowserWindowController(tab: tab)
        windows.append(controller)
        controller.showWindow(nil)
        if let window = controller.window {
            if let point {
                window.setFrameOrigin(NSPoint(x: point.x - 60, y: point.y - 30))
            } else {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    var keyController: BrowserWindowController? {
        controller(for: NSApp.keyWindow) ?? windows.first { $0.window?.isKeyWindow == true }
    }

    func controller(for window: NSWindow?) -> BrowserWindowController? {
        guard let window else { return nil }
        return windows.first { $0.window === window }
    }

    func close(_ controller: BrowserWindowController) {
        controller.close()
    }

    func closeSelectedTab() {
        guard let controller = keyController, let tab = controller.selectedTab else { return }
        controller.closeTab(tab)
    }

    // MARK: - Tabs

    /// Adds a tab to `controller`, or to the key window's controller,
    /// falling back to a new window.
    @discardableResult
    func newTab(
        url: URL? = nil,
        privacyMode: BrowserPrivacyMode = .regular,
        in controller: BrowserWindowController? = nil
    ) -> BrowserTab? {
        let target = controller ?? keyController
        let tab = BrowserTab(privacyMode: privacyMode, history: history, initialURL: url)
        if let target {
            target.addTab(tab)
        } else {
            newWindow(containing: tab)
        }
        return tab
    }

    func recordClosedTab(_ tab: BrowserTab) {
        // Snapshot, don't retain: reopening rebuilds the tab from its
        // URL, so the closed tab and its web view deallocate now.
        recentlyClosed.append(ClosedTab(url: tab.tabController.url, privacyMode: tab.privacyMode))
        trimRecentlyClosed()
    }

    func reopenClosedTab() {
        guard let closed = recentlyClosed.popLast() else {
            SystemBeep.play()
            return
        }
        let tab = BrowserTab(privacyMode: closed.privacyMode, history: history, initialURL: closed.url)
        if let controller = keyController {
            controller.addTab(tab)
            controller.selectTab(tab)
        } else {
            newWindow(containing: tab)
        }
    }

    func selectNextTab() {
        guard let controller = keyController else { return }
        controller.selectTab(atOffset: 1)
    }

    func selectPreviousTab() {
        guard let controller = keyController else { return }
        controller.selectTab(atOffset: -1)
    }

    func selectTab(at index: Int) {
        guard let controller = keyController,
              controller.tabs.indices.contains(index)
        else {
            return
        }
        controller.selectTab(controller.tabs[index])
    }

    /// Finds a live tab across every window, including tabs whose window
    /// is mid-drag. Used to resolve a drag payload.
    func tab(withIDString string: String) -> BrowserTab? {
        guard let id = UUID(uuidString: string) else { return nil }
        for controller in windows {
            if let tab = controller.tabs.first(where: { $0.id == id }) {
                return tab
            }
        }
        return nil
    }

    /// Called by a drag that ended outside every browser window. The tab
    /// becomes a new window at that point.
    func dragEndedOutsideApp(_ tab: BrowserTab, atScreenPoint point: NSPoint) {
        guard let source = windows.first(where: {
            $0.tabs.contains { $0.id == tab.id }
        }) else {
            return
        }
        detach(tab: tab, from: source, atScreenPoint: point)
    }

    /// Moves a tab into another window at a given index. The source
    /// window closes itself if it empties.
    func moveTab(
        _ tab: BrowserTab,
        to index: Int,
        in destination: BrowserWindowController
    ) {
        guard destination.tabs.allSatisfy({ $0.id != tab.id }) else { return }
        let source = windows.first {
            $0.tabs.contains { $0.id == tab.id }
        }
        guard let source, source !== destination else {
            destination.moveTab(tab, to: index)
            return
        }
        source.detachTab(tab)
        destination.addTab(tab, at: index)
    }

    /// Moves a tab to a new window, removing it from `source`. Used when
    /// a drag ends outside every browser window.
    func detach(
        tab: BrowserTab,
        from source: BrowserWindowController,
        atScreenPoint point: NSPoint
    ) {
        guard source.tabs.contains(where: { $0.id == tab.id }) else { return }
        // Keep the tab's session alive: nothing about the tab is torn
        // down, only its membership of `source` changes.
        source.detachTab(tab)
        newWindow(containing: tab, atScreenPoint: point)
    }

    // MARK: - Private

    private func windowWillClose(_ window: NSWindow) {
        guard let controller = windows.first(where: { $0.window === window }) else { return }
        // The window's tabs go on the reopen stack in close order.
        recentlyClosed.append(contentsOf: controller.tabs.reversed().map {
            ClosedTab(url: $0.tabController.url, privacyMode: $0.privacyMode)
        })
        trimRecentlyClosed()
        controller.tearDown()
        windows.removeAll { $0 === controller }
    }

    private func trimRecentlyClosed() {
        if recentlyClosed.count > maxRecentlyClosed {
            recentlyClosed.removeFirst(recentlyClosed.count - maxRecentlyClosed)
        }
    }
}
