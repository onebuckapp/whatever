import AppKit
import Combine
import WebKit

/// One browser window. A window owns an ordered list of tabs (a tab
/// always belongs to exactly one window) plus, separately, a content
/// layout that decides what the page area shows:
/// `.single` renders one tab, `.split` renders two tabs side by side.
/// Splitting therefore changes presentation only: the tabs stay in the
/// window's collection and in the tab bar.
final class BrowserWindowController: NSWindowController {
    enum ContentLayout: Equatable {
        case single(tabID: UUID)
        case split(leadingTabID: UUID, trailingTabID: UUID, ratio: CGFloat)
    }

    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedTabID: UUID?
    private(set) var layout: ContentLayout

    private let activeModel = ActivePaneModel()
    private var toolbarController: BrowserToolbarController!
    private let contentController: BrowserWindowContentViewController
    private let dropPreview = SplitDropPreviewView()

    private var splitController: BrowserSplitViewController?
    private var singlePane: BrowserPaneController?
    private var paneCache: [UUID: BrowserPaneController] = [:]
    private var titleSubscription: AnyCancellable?
    private var progressCancellables = Set<AnyCancellable>()
    private var menuTargets: [UUID: TabMenuTarget] = [:]

    // MARK: - Init

    init(tab: BrowserTab) {
        self.layout = .single(tabID: tab.id)

        let content = BrowserWindowContentViewController()
        self.contentController = content

        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        super.init(window: window)

        // The toolbar controller needs this controller, so it can only
        // be built after super.init.
        let toolbarController = BrowserToolbarController(controller: self)
        self.toolbarController = toolbarController
        window.toolbarStyle = .unified
        window.toolbar = toolbarController.windowToolbar

        tabs = [tab]
        tab.onWebViewReplaced = { [weak self, weak tab] in
            guard let tab else { return }
            self?.webViewReplaced(for: tab)
        }
        content.installDropPreview(dropPreview)
        content.setNewTabAction { [weak self] in
            guard let self else { return }
            BrowserCoordinator.shared.newTab(in: self)
        }
        contentController.tabBar.strip.delegate = self
        contentController.tabBar.strip.owner = self
        contentController.onDropZoneChanged = { [weak self] zone in
            guard let self else { return }
            if let zone {
                self.dropPreview.present(zone: zone, animated: true)
            } else {
                self.dropPreview.dismiss()
            }
        }
        contentController.onTabDropped = { [weak self] tab, zone in
            self?.handleSplitDrop(of: tab, zone: zone)
        }
        toolbarController.onAddressSubmitted = { [weak self] url in
            self?.selectedTab?.navigate(to: url)
        }
        toolbarController.onGrainSettings = { [weak self] in
            guard let self else { return }
            self.contentController.toggleNoiseSettings()
        }

        selectTab(tab)
        refresh()

        // Must come after init: with a hidden transparent titlebar,
        // sizing the content before super.init is lost and the window
        // collapses to content fitting size on first show.
        window.setContentSize(NSSize(width: 1300, height: 840))
    }

    convenience init(
        initialURL: URL? = nil,
        privacyMode: BrowserPrivacyMode = .regular,
        history: HistoryRecording
    ) {
        self.init(tab: BrowserTab(privacyMode: privacyMode, history: history, initialURL: initialURL))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Tabs

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// Tabs the page area is currently showing.
    var displayedTabs: [BrowserTab] {
        switch layout {
        case .single(let tabID):
            return tabs.filter { $0.id == tabID }
        case .split(let leading, let trailing, _):
            return [leading, trailing].compactMap { id in tabs.first { $0.id == id } }
        }
    }

    var isSplit: Bool {
        if case .split = layout {
            return true
        }
        return false
    }

    func addTab(_ tab: BrowserTab, at index: Int? = nil, select: Bool = true) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        tab.onWebViewReplaced = { [weak self, weak tab] in
            guard let tab else { return }
            self?.webViewReplaced(for: tab)
        }
        let target = min(max(0, index ?? tabs.count), tabs.count)
        tabs.insert(tab, at: target)
        if select {
            selectTab(tab)
        } else {
            refresh()
        }
    }

    func selectTab(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }

        dismissQRCode()

        selectedTabID = tab.id
        activeModel.activeTabID = tab.id
        toolbarController.setTab(tab)
        bindProgress(to: tab)
        titleSubscription = tab.tabController.$title.sink { [weak self] title in
            self?.window?.title = title
        }
        window?.title = tab.tabController.title

        // Selecting a tab that is not part of a split collapses to it.
        if !displayedTabs.contains(where: { $0.id == tab.id }) {
            layout = .single(tabID: tab.id)
        }
        refresh()
    }

    /// Drives the 2pt indicator under the toolbar from the active tab.
    private func bindProgress(to tab: BrowserTab) {
        progressCancellables.removeAll()
        tab.tabController.$estimatedProgress
            .combineLatest(tab.tabController.$isLoading)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress, isLoading in
                self?.contentController.updateProgress(progress, isLoading: isLoading)
            }
            .store(in: &progressCancellables)
    }

    func moveTab(_ tab: BrowserTab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: min(max(0, index), tabs.count))
        refresh()
    }

    @discardableResult
    func duplicateTab(_ tab: BrowserTab) -> BrowserTab {
        // A blank page duplicates as a fresh homepage, not as about:blank.
        let url = tab.tabController.url
        let copy = BrowserTab(
            privacyMode: tab.privacyMode,
            history: BrowserCoordinator.shared.history,
            initialURL: url?.isAddresslessPage == true ? nil : url
        )
        let index = tabs.firstIndex(where: { $0.id == tab.id }).map { $0 + 1 }
        addTab(copy, at: index)
        return copy
    }

    /// Adds an already existing tab, e.g. one created for another
    /// window or reopened from history.
    @discardableResult
    func addExistingTab(_ tab: BrowserTab) -> BrowserTab {
        addTab(tab)
        return tab
    }

    /// Selects the tab `offset` positions along the tab bar.
    func selectTab(atOffset offset: Int) {
        guard !tabs.isEmpty, let selected = selectedTab,
              let index = tabs.firstIndex(where: { $0.id == selected.id })
        else {
            SystemBeep.play()
            return
        }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Releases window-owned state. Tabs survive so they can be reopened
    /// or adopted by another window.
    func tearDown() {
        for tab in tabs {
            paneCache.removeValue(forKey: tab.id)?.view.removeFromSuperview()
            tab.webView.removeFromSuperview()
        }
        paneCache.removeAll()
        menuTargets.removeAll()
        progressCancellables.removeAll()
        titleSubscription = nil
    }

    /// Removes a tab without closing it, so another window can adopt
    /// it. An emptied window closes itself.
    func detachTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)

        switch layout {
        case .split(let leading, let trailing, let ratio):
            if leading == tab.id {
                layout = .split(leadingTabID: trailing, trailingTabID: trailing, ratio: ratio)
            } else if trailing == tab.id {
                layout = .split(leadingTabID: leading, trailingTabID: leading, ratio: ratio)
            }
        case .single(let tabID) where tabID == tab.id:
            // `index` may now point past the end when the detached tab
            // was last; clamp like the selection below does.
            layout = tabs.isEmpty
                ? .single(tabID: tab.id)
                : .single(tabID: tabs[min(index, tabs.count - 1)].id)
        case .single:
            break
        }

        paneCache.removeValue(forKey: tab.id)?.view.removeFromSuperview()
        tab.webView.removeFromSuperview()
        menuTargets.removeValue(forKey: tab.id)

        if tabs.isEmpty {
            BrowserCoordinator.shared.close(self)
        } else {
            selectTab(tabs[min(index, tabs.count - 1)])
        }
    }

    /// Removes a tab. The last tab closes the window; a removed tab
    /// leaves the split so it stops being displayed.
    func removeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)

        switch layout {
        case .single(let tabID) where tabID == tab.id:
            // `index` may now point past the end when the closed tab was
            // last; clamp like the selection below does.
            layout = tabs.isEmpty
                ? .single(tabID: tab.id)
                : .single(tabID: tabs[min(index, tabs.count - 1)].id)
        case .split(let leading, let trailing, let ratio):
            if leading == tab.id {
                layout = .split(leadingTabID: trailing, trailingTabID: trailing, ratio: ratio)
            } else if trailing == tab.id {
                layout = .split(leadingTabID: leading, trailingTabID: leading, ratio: ratio)
            }
        case .single:
            break
        }

        paneCache.removeValue(forKey: tab.id)?.view.removeFromSuperview()
        tab.webView.removeFromSuperview()
        menuTargets.removeValue(forKey: tab.id)

        if tabs.isEmpty {
            BrowserCoordinator.shared.close(self)
            return
        }

        let next = selectedTabID.flatMap { id in tabs.first { $0.id == id } }
            ?? tabs[min(index, tabs.count - 1)]
        selectTab(next)
    }

    func closeTab(_ tab: BrowserTab) {
        BrowserCoordinator.shared.recordClosedTab(tab)
        removeTab(tab)
    }

    func closeOtherTabs(except tab: BrowserTab) {
        for other in tabs where other.id != tab.id {
            removeTab(other)
        }
    }

    func closeTabs(toTheRightOf tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        for other in tabs[(index + 1)...] {
            removeTab(other)
        }
    }

    // MARK: - Split view

    /// Splits `currentTab` with `droppedTab` in the given direction.
    /// Transactional: the layout only changes when both tabs are known
    /// and the zone is a real half.
    @discardableResult
    func createSplit(
        currentTab: BrowserTab,
        droppedTab: BrowserTab,
        zone: SplitDropZone
    ) -> Bool {
        guard currentTab.id != droppedTab.id else { return false }
        guard tabs.contains(where: { $0.id == currentTab.id }),
              tabs.contains(where: { $0.id == droppedTab.id })
        else {
            return false
        }

        let ratio: CGFloat = BrowserSplitViewController.defaultRatio
        switch zone {
        case .leading:
            layout = .split(
                leadingTabID: droppedTab.id,
                trailingTabID: currentTab.id,
                ratio: ratio
            )
        case .trailing:
            layout = .split(
                leadingTabID: currentTab.id,
                trailingTabID: droppedTab.id,
                ratio: ratio
            )
        case .center:
            return false
        }

        rebuildSplitView()
        selectTab(droppedTab)
        return true
    }

    /// Drops a tab onto an existing split: it replaces the pane on that
    /// side, and the tab it displaced returns to being just a tab.
    func replacePane(with tab: BrowserTab, zone: SplitDropZone) {
        guard case .split(let leading, let trailing, let ratio) = layout else {
            if let current = selectedTab {
                createSplit(currentTab: current, droppedTab: tab, zone: zone)
            }
            return
        }
        switch zone {
        case .leading:
            layout = .split(leadingTabID: tab.id, trailingTabID: trailing, ratio: ratio)
        case .trailing:
            layout = .split(leadingTabID: leading, trailingTabID: tab.id, ratio: ratio)
        case .center:
            return
        }
        rebuildSplitView()
        selectTab(tab)
    }

    /// Splits the selected tab with the next tab in the tab bar.
    func splitWithNextTab() {
        guard let tab = selectedTab,
              let index = tabs.firstIndex(where: { $0.id == tab.id }),
              tabs.indices.contains(index + 1)
        else {
            SystemBeep.play()
            return
        }
        if isSplit {
            replacePane(with: tabs[index + 1], zone: .trailing)
        } else {
            createSplit(currentTab: tab, droppedTab: tabs[index + 1], zone: .trailing)
        }
    }

    func splitWithPreviousTab() {
        guard let tab = selectedTab,
              let index = tabs.firstIndex(where: { $0.id == tab.id }),
              index > 0
        else {
            SystemBeep.play()
            return
        }
        if isSplit {
            replacePane(with: tabs[index - 1], zone: .leading)
        } else {
            createSplit(currentTab: tab, droppedTab: tabs[index - 1], zone: .leading)
        }
    }

    /// Removes the pane showing `tab` and collapses back to one pane.
    func closePane(_ tab: BrowserTab) {
        guard isSplit else {
            closeTab(tab)
            return
        }
        let remaining = displayedTabs.first { $0.id != tab.id }
        guard let remaining else {
            closeTab(tab)
            return
        }
        layout = .single(tabID: remaining.id)
        rebuildContent()
        selectTab(remaining)
    }

    func collapseSplit() {
        guard isSplit, let tab = selectedTab ?? displayedTabs.first else { return }
        layout = .single(tabID: tab.id)
        rebuildContent()
    }

    func focusNextPane() {
        focusPane(step: 1)
    }

    func focusPreviousPane() {
        focusPane(step: -1)
    }

    private func focusPane(step: Int) {
        let visible = displayedTabs
        guard visible.count > 1, let tab = selectedTab,
              let index = visible.firstIndex(where: { $0.id == tab.id })
        else {
            SystemBeep.play()
            return
        }
        let next = visible[(index + step + visible.count) % visible.count]
        selectTab(next)
        window?.makeFirstResponder(next.webView)
    }

    // MARK: - Drop handling

    /// Commits a tab drop onto the page area: the tab stays in this
    /// window's tab bar and only its presentation changes.
    func handleSplitDrop(of tab: BrowserTab, zone: SplitDropZone) {
        guard zone != .center else {
            SystemBeep.play()
            return
        }
        if isSplit {
            replacePane(with: tab, zone: zone)
        } else if let current = selectedTab {
            createSplit(currentTab: current, droppedTab: tab, zone: zone)
        }
    }

    // MARK: - Refresh

    func refresh() {
        normalizeTabOrder()
        refreshTabBar()
        rebuildContent()
        let minimumWidth: CGFloat = isSplit ? 560 : 360
        window?.contentMinSize = NSSize(width: minimumWidth, height: 320)
    }

    func refreshTabBar() {
        contentController.tabBar.strip.setTabs(tabs, selectedTabID: selectedTabID)
    }

    /// Pinned tabs always lead the bar. Keeping that invariant in the
    /// model means the tab bar's drop indices are model indices.
    private func normalizeTabOrder() {
        guard tabs.contains(where: \.presentation.isPinned) else { return }
        let ordered = tabs.filter(\.presentation.isPinned)
            + tabs.filter { !$0.presentation.isPinned }
        guard ordered != tabs else { return }
        tabs = ordered
    }

    func tabMenuTarget(for tab: BrowserTab) -> TabMenuTarget {
        if let existing = menuTargets[tab.id] {
            existing.rebind(tab: tab)
            return existing
        }
        let target = TabMenuTarget(controller: self, tab: tab)
        menuTargets[tab.id] = target
        return target
    }

    // MARK: - Content

    /// Rehosts the tab's replacement view after a navigation swapped it:
    /// the old pane is discarded and a new pane hosts the new view.
    private func webViewReplaced(for tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        dismissQRCode()
        paneCache.removeValue(forKey: tab.id)
        rebuildContent()
    }

    private func pane(for tab: BrowserTab) -> BrowserPaneController {
        if let cached = paneCache[tab.id] {
            return cached
        }
        let pane = BrowserPaneController(tab: tab, activeModel: activeModel)
        paneCache[tab.id] = pane
        return pane
    }

    // MARK: - QR code

    /// Shows the QR card for `tab`'s page over that tab's pane.
    func presentQRCode(for tab: BrowserTab) {
        guard let url = tab.webView.url, !url.isAddresslessPage else {
            SystemBeep.play()
            return
        }
        // A hidden tab has no pane in the current layout. Show it first so
        // the card has a visible page to cover.
        if !displayedTabs.contains(where: { $0.id == tab.id }) {
            selectTab(tab)
        }
        pane(for: tab).presentQRCode(text: url.absoluteString)
    }

    /// Closes every open QR card, used when the layout or selection changes
    /// out from under one.
    func dismissQRCode() {
        for pane in paneCache.values {
            pane.dismissQRCode()
        }
    }

    /// Rebuilds the page area for the current layout, reusing cached
    /// panes so web views are reparented instead of recreated.
    private func rebuildContent() {
        dismissQRCode()
        let visible = displayedTabs
        if visible.count <= 1 {
            splitController = nil
            singlePane = nil
            if let tab = visible.first {
                contentController.showChild(pane(for: tab))
            }
            activeModel.showsIndicator = false
            return
        }
        rebuildSplitView()
    }

    private func rebuildSplitView() {
        guard case .split(let leading, let trailing, let ratio) = layout else {
            rebuildContent()
            return
        }
        let visible = displayedTabs
        guard visible.count == 2 else {
            rebuildContent()
            return
        }

        let split: BrowserSplitViewController
        if let existing = splitController {
            split = existing
        } else {
            split = BrowserSplitViewController()
            splitController = split
            singlePane = nil
            split.onRatioChange = { [weak self] newRatio in
                guard let self, case .split = self.layout else { return }
                self.layout = .split(
                    leadingTabID: leading,
                    trailingTabID: trailing,
                    ratio: min(
                        max(newRatio, BrowserSplitViewController.minimumRatio),
                        BrowserSplitViewController.maximumRatio
                    )
                )
            }
        }

        let wanted = visible.map { pane(for: $0) }
        for pane in split.paneControllers where !wanted.contains(where: { $0 === pane }) {
            split.removePane(pane)
        }
        for pane in wanted where !split.paneControllers.contains(where: { $0 === pane }) {
            split.addPane(pane)
        }
        contentController.showChild(split)
        activeModel.showsIndicator = true
        // Ratio can only be applied once the view has a width.
        split.view.layoutSubtreeIfNeeded()
        split.setRatio(ratio)
    }
}

// MARK: - TabBarViewDelegate

extension BrowserWindowController: TabBarViewDelegate {
    func tabBar(_ tabBar: TabBarView, didSelect tab: BrowserTab) {
        selectTab(tab)
    }

    func tabBar(_ tabBar: TabBarView, didClose tab: BrowserTab) {
        closeTab(tab)
    }

    func tabBar(_ tabBar: TabBarView, menuFor tab: BrowserTab) -> NSMenu? {
        BrowserTabContextMenu.menu(for: tab, controller: self)
    }

    func tabBar(_ tabBar: TabBarView, didDropTab tab: BrowserTab, at index: Int) {
        BrowserCoordinator.shared.moveTab(tab, to: index, in: self)
    }
}
