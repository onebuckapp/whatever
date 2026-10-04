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

    let history: HistoryRecording = StoreHistoryRecorder()

    private(set) var windows: [BrowserWindowController] = []
    /// Pushes the live half of the web settings onto every open page.
    ///
    /// Only the `WKWebView` properties can be changed this way; the rest are read
    /// when a view is built, so those take effect on the next page. Called from
    /// `SettingsStore.onChange` rather than from each control, so a change made
    /// anywhere lands the same way.
    func applyLiveWebSettings() {
        let settings = SettingsStore.shared.settings.web
        for window in windows {
            for tab in window.tabs {
                // Skips tabs with no view: they read the configuration half when
                // they are built, and there is nothing to push live settings onto.
                guard let webView = tab.webView else { continue }
                settings.apply(toWebView: webView)
            }
        }
    }

    /// Pushes the window background onto every open page.
    ///
    /// Only the page-transparency part needs pushing: the background layer
    /// itself reads the store directly, one subscription per window.
    func applyLiveBackgroundSettings() {
        let background = SettingsStore.shared.settings.appearance.background
        // Inert unless there is a background to reveal. A transparent page over
        // the plain window colour is a different appearance, not this feature.
        let enabled = background.isActive && background.showThroughPages
        for window in windows {
            for tab in window.tabs {
                guard let webView = tab.webView else { continue }
                PageTransparency.apply(enabled: enabled, to: webView)
            }
        }
    }
    /// Suppresses session writes while a session is being rebuilt.
    ///
    /// Restoring runs the same `addTab` and `selectTab` paths as any other
    /// change, so without this the first window would schedule a write of a
    /// half-restored session over the one being read.
    private var isRestoringSession = false

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

    // MARK: - Session

    /// Builds the document that describes every open window.
    ///
    /// Private tabs are left out here rather than marked in the document: a
    /// private tab is not the user's to reopen later, so it should not survive
    /// in a file either. The address is the tab's own rather than its loaded
    /// page's, so a tab that never got a view still records where it was.
    func sessionSnapshot() -> SessionSnapshot {
        let records = windows.compactMap { controller -> SessionSnapshot.WindowSnapshot? in
            guard let window = controller.window else { return nil }
            let tabs = controller.tabs.compactMap { tab -> SessionSnapshot.TabSnapshot? in
                guard tab.privacyMode != .privateBrowsing else { return nil }
                let slice = tab.historySnapshot()
                return SessionSnapshot.TabSnapshot(
                    id: tab.id,
                    url: tab.currentURL.absoluteString,
                    title: tab.tabController.title,
                    isPinned: tab.presentation.isPinned,
                    history: slice.urls.map(\.absoluteString),
                    historyIndex: slice.index,
                    isMuted: tab.tabController.isMuted
                )
            }
            guard !tabs.isEmpty else { return nil }
            // The layout can name a private tab that the filter above just
            // dropped, so it is rebuilt from what survived.
            let kept = Set(tabs.map(\.id))
            let layout: SessionSnapshot.WindowSnapshot.Layout
            switch controller.layout {
            case .single(let tabID):
                layout = .single(kept.contains(tabID) ? tabID : (tabs.first?.id ?? UUID()))
            case .split(let leading, let trailing, let ratio):
                let canRestoreBoth = kept.contains(leading)
                    && kept.contains(trailing)
                    && leading != trailing
                layout = canRestoreBoth
                    ? .split(leading: leading, trailing: trailing, ratio: Double(ratio))
                    : .single(kept.contains(leading) ? leading : (tabs.first?.id ?? UUID()))
            }
            return SessionSnapshot.WindowSnapshot(
                frame: .init(window.frame),
                tabs: tabs,
                selectedTabID: controller.selectedTabID.flatMap { kept.contains($0) ? $0 : nil },
                layout: layout
            )
        }
        return SessionSnapshot(windows: records)
    }

    /// Reopens a stored session.
    ///
    /// Returns how many windows came back, so the caller can open a fresh one
    /// when there was nothing to restore.
    @discardableResult
    func restore(from snapshot: SessionSnapshot?) -> Int {
        guard let snapshot, snapshot.isRestorable else { return 0 }
        isRestoringSession = true
        defer { isRestoringSession = false }
        var restored = 0
        for record in snapshot.windows where !record.tabs.isEmpty {
            let controller = BrowserWindowController(restoring: record, history: history)
            windows.append(controller)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            restored += 1
        }
        return restored
    }

    /// Schedules a session write.
    ///
    /// The single entry point for every change worth recording, so a new kind of
    /// mutation cannot quietly skip persistence by being added somewhere that
    /// forgets to call this.
    func sessionDidChange() {
        guard !isRestoringSession else { return }
        let snapshot = sessionSnapshot()
        Task { await SessionStore.shared.scheduleSave(snapshot) }
    }

    /// Writes the session immediately, for the quit and window-close paths.
    func saveSessionNow() async {
        await SessionStore.shared.saveNow(sessionSnapshot())
    }

    /// Whether a session write has not reached the store yet.
    ///
    /// The quit path reads this to decide whether it needs to delay termination
    /// at all, so a quit with nothing pending does not wait on a round trip.
    func hasPendingSessionWrite() async -> Bool {
        await SessionStore.shared.hasPendingWrite
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
        // `displayURL` rather than the loaded page's URL, so reopening a tab that
        // was never realized lands on the address it was sitting at.
        recentlyClosed.append(ClosedTab(url: tab.displayURL, privacyMode: tab.privacyMode))
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

    /// Moves a tab to a new window, removing it from `source`, which closes
    /// itself if that leaves it empty. A screen point positions the new window
    /// under the drop; without one it is centred.
    func detach(
        tab: BrowserTab,
        from source: BrowserWindowController,
        atScreenPoint point: NSPoint? = nil
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
            ClosedTab(url: $0.displayURL, privacyMode: $0.privacyMode)
        })
        trimRecentlyClosed()
        controller.tearDown()
        windows.removeAll { $0 === controller }
        // After the removal, so the snapshot describes what is still open. The
        // frame is captured while the window still exists.
        sessionDidChange()
    }

    private func trimRecentlyClosed() {
        if recentlyClosed.count > maxRecentlyClosed {
            recentlyClosed.removeFirst(recentlyClosed.count - maxRecentlyClosed)
        }
    }
}
