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

/// Owns the spotlight field and the dropdown under it: the query, the debounce, the
/// results, and which row is selected.
///
/// The two views are siblings rather than parent and child, because they share one
/// outline. `SpotlightField` squares its bottom corners while open and
/// `SpotlightDropdown` keeps its top corners square, so the two together read as a
/// single shape split by a hairline — which a child view could not do, since a
/// child's background would be clipped by the parent's corner radius.
@MainActor
final class SpotlightController {
    private weak var fieldView: SpotlightField?
    private weak var container: NSView?
    private var dropdown: SpotlightDropdown?

    private var results: [HistoryFuzzyEntry] = []
    private var selectedIndex: Int?

    private var pendingSearch: Task<Void, Never>?
    private var generation = 0
    /// Held only while the panel is open. See `installOutsideClickMonitor`.
    private var outsideClickMonitor: Any?

    /// Told to navigate when a row is chosen, so this knows nothing about tabs.
    var onNavigate: ((URL) -> Void)?

    private static let debounce: Duration = .milliseconds(150)
    /// A dropdown showing everything is not autocomplete, it is a history dump.
    private static let minimumQueryLength = 2
    private static let resultLimit = 12

    /// Whether the dropdown is showing. Driven by the panel's hidden flag rather than
/// by its presence in the view tree: the panel stays parented while closed, so
    /// `superview` would always be non-nil.
    var isOpen: Bool { !(dropdown?.isHidden ?? true) }

    /// Explicit panel width, synced from the field. The panel used to share the
    /// field's edges through two pins, but a long row's width demand travelled
    /// that linkage backwards and parked the whole bar at content size. A set
    /// width constant is solver input rather than an outcome, so content can
    /// no longer move or resize anything no matter what priority it arrives
    /// with; the leading pin keeps the left edges glued.
    private var dropdownWidth: NSLayoutConstraint?
    private var fieldFrameObserver: Any?

    private var selectedEntry: HistoryFuzzyEntry? {
        guard let selectedIndex, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    /// `container` is the window's content view: the dropdown is added there so it can
    /// cover the tab bar and the page, rather than into the toolbar strip where it
    /// would be clipped to 52pt.
    func attach(field: SpotlightField, container: NSView? = nil) {
        fieldView = field
        if let container { self.container = container }
        field.onTextChanged = { [weak self] text in self?.queryChanged(text) }
        field.onSubmit = { [weak self] _ in
            guard let self else { return }
            // Only an explicitly highlighted row wins over the text. A merely
            // visible top hit must not: Enter on typed text searches for that
            // text rather than opening whatever happened to rank first.
            if self.chooseSelected() { return }
            self.submitTyped(field.textField.stringValue)
        }
        field.onActivated = { [weak self] in
            guard let self, !self.isOpen else { return }
            // Every visit to the bar offers somewhere to go: empty shows the most
            // recent history, typed text re-queries as-is. Opening is left to the
            // results arriving rather than forced up front, so a query that misses
            // never flashes the panel open just to close it. An already-open panel
            // is current by construction — text cannot change without querying —
            // so it is left alone instead of rebuilt under the mouse.
            self.queryChanged(field.textField.stringValue, preopen: false)
        }
        field.onMoveSelection = { [weak self] offset in self?.moveSelection(by: offset) }
        field.onDismiss = { [weak self] in self?.close() }
    }

    // MARK: - Querying

    /// - Parameter preopen: Whether the panel opens before the results arrive.
    /// Typing pre-opens so the bar's corners square up immediately; a
    /// focus-triggered query does not, so a query that misses never flashes an
    /// empty panel open just to close it.
    func queryChanged(_ text: String, preopen: Bool = true) {
        generation += 1
        let generation = self.generation
        pendingSearch?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty means "most recent", not "nothing": clearing the field should still
        // offer somewhere to go. Below the minimum, nothing — one character is not
        // a search, it is a prefix, and a dropdown of everything for it is noise.
        guard !trimmed.isEmpty else {
            showMostRecent()
            return
        }
        // The search row answers keystrokes, not the debounce: it is built from
        // the live text on every press, so it is always current while the
        // history below it is still arriving. A lone character gets the row
        // without a history query behind it.
        showSearchRow(for: trimmed, open: preopen)
        guard trimmed.count >= Self.minimumQueryLength else {
            return
        }
        // Opened before the query returns, so the panel is on screen with the bar's
        // own shape while it waits. Without this the bar's bottom corners stay
        // rounded with nothing under them and the join only appears a beat later.
        if preopen {
            openPanel()
        }

        pendingSearch = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let payload: Data
            do {
                payload = try await StoreClient.shared.fuzzySearchHistory(
                    trimmed,
                    limit: Self.resultLimit
                )
            } catch {
                return
            }
            guard !Task.isCancelled, generation == self.generation else { return }
            self.present(HistoryFuzzyEntry.decodeList(payload), preselectFirst: false)
        }
    }

    /// Shows just the search row for the live text, keeping a highlight the
    /// user already placed by id: typing on with the row arrowed on must not
    /// drop it.
    private func showSearchRow(for trimmed: String, open: Bool) {
        let engine = SettingsStore.shared.settings.search.engine()
        let row = HistoryFuzzyEntry.searchRow(query: trimmed, engine: engine)
        let keep = selectedEntry?.id
        results = row.map { [$0] } ?? []
        selectedIndex = keep.flatMap { id in results.firstIndex(where: { $0.id == id }) }
        guard !results.isEmpty else {
            close()
            return
        }
        refreshResults()
        if open {
            openPanel()
        }
    }

    private func showMostRecent() {
        pendingSearch?.cancel()
        // Captured, not re-read: keystrokes after this bump the generation,
        // and recents arriving late must not land over typed text.
        let generation = self.generation
        Task { [weak self] in
            guard let self else { return }
            let payload: Data
            do {
                payload = try await StoreClient.shared.recentHistory(limit: Self.resultLimit)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.present(
                HistoryEntry.decodeList(payload).map(HistoryFuzzyEntry.init),
                generation: generation
            )
        }
    }

    private func present(
        _ entries: [HistoryFuzzyEntry],
        preselectFirst: Bool = true,
        generation: Int? = nil
    ) {
        // Stale recents over fresh typing: the field moved on while the store
        // answered, so this answer is for nobody.
        if let generation, generation != self.generation { return }
        // Rebuilt from the field's live text, not the queried one: the search
        // row names what is on screen now, and history arriving late must not
        // push a row for stale text above it.
        let live = fieldView?.textField.stringValue ?? ""
        let engine = SettingsStore.shared.settings.search.engine()
        let row = HistoryFuzzyEntry.searchRow(query: live, engine: engine)
        // Captured before the swap: `selectedEntry` reads `results`, so after
        // this line it would name the new list's row, not the user's.
        let keep = selectedEntry?.id
        results = row.map { [$0] + entries } ?? entries
        // Typed-query results never preselect: arrow-down reaches the first
        // row, and Enter on unhighlighted text submits that text. Recent
        // history keeps its longstanding top-row selection. A highlight the
        // user placed survives the history landing under it, but clearing
        // the field is a fresh start: the old highlight stays behind.
        if !preselectFirst,
           let keep = selectedEntry?.id,
           let index = results.firstIndex(where: { $0.id == keep })
        {
            selectedIndex = index
        } else {
            selectedIndex = results.isEmpty || !preselectFirst ? nil : 0
        }
        // No history is not no answer: the search row alone still offers
        // somewhere to go. Only a missing row closes the panel.
        guard !results.isEmpty else {
            close()
            return
        }
        refreshResults()
        openPanel()
    }

    // MARK: - Panel

/// Creates the panel once, already parented and pinned to the bar's bottom edge.
    ///
    /// Never removed from the content view. Taking a view out of its superview
    /// deactivates every constraint that crosses out of it, so a panel removed on
    /// close comes back with no width at all — 160pt, from its content, ambiguous,
    /// and wherever AutoLayout felt like — and reinstalling the pins on each open
    /// stacked up duplicates rather than fixing it. Hiding it instead keeps every
    /// constraint valid for the window's whole life.
    private func panel() -> SpotlightDropdown? {
        if let dropdown { return dropdown }
        guard let container, let fieldView else { return nil }
        let dropdown = SpotlightDropdown()
        dropdown.translatesAutoresizingMaskIntoConstraints = false
        dropdown.isHidden = true
        container.addSubview(dropdown)
        NSLayoutConstraint.activate([
            // Same left edge and top join as before. The width is a synced
            // constant, not a trailing pin (see `dropdownWidth`): with the
            // panel width an input, its content is fully decoupled from the
            // bar's geometry.
            dropdown.topAnchor.constraint(equalTo: fieldView.bottomAnchor, constant: -1),
            dropdown.leadingAnchor.constraint(equalTo: fieldView.leadingAnchor),
        ])
        dropdownWidth = dropdown.widthAnchor.constraint(equalToConstant: fieldView.frame.width)
        dropdownWidth?.isActive = true
        syncDropdownWidth()
        // Window resizes re-lay the bar; the panel follows the field there
        // instead of through a constraint, so it needs to hear about it.
        fieldView.postsFrameChangedNotifications = true
        fieldFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: fieldView,
            queue: .main
        ) { [weak self] _ in
            self?.syncDropdownWidth()
        }
        self.dropdown = dropdown
        return dropdown
    }

    /// Copies the field's live width into the panel's width constraint.
    /// Guarded: equal values must not re-mark the layout dirty on every
    /// frame notification, or resizes would loop layout passes.
    private func syncDropdownWidth() {
        guard let fieldView, let dropdownWidth else { return }
        let width = fieldView.frame.width
        guard dropdownWidth.constant != width else { return }
        dropdownWidth.constant = width
    }

    private func openPanel() {
        guard let container, let fieldView else { return }
        // Created on first use, since the container does not exist when the toolbar
        // is constructed.
        guard let dropdown = panel() else { return }
        dropdown.isHidden = false
        // The bar may have resized while the panel was closed; pick the live
        // width up before showing rather than flashing the stale one.
        syncDropdownWidth()
        // Moved to the front so a card opening later cannot bury it. Safe to repeat
        // on a view that is already parented, and the constraints are relative to
        // the bar so nothing depends on its position in the view list.
        container.addSubview(dropdown, positioned: .above, relativeTo: nil)
        fieldView.isOpen = true
        installOutsideClickMonitor()
    }

    private func close() {
        pendingSearch?.cancel()
        pendingSearch = nil
        generation += 1
        results = []
        selectedIndex = nil
        fieldView?.isOpen = false
        // Hidden, never removed: see `panel`. Removing it is what threw away the
        // constraints pinning it to the bar, which left it 160pt wide with no layout
        // of its own the next time it was opened.
        dropdown?.isHidden = true
        dropdown?.clearResults()
        removeOutsideClickMonitor()
    }

    // MARK: - Clicking away

    /// Dismissed by a press anywhere outside the field and the panel: clicking into
    /// the page, the tab bar or a toolbar button should put the spotlight away.
    ///
    /// Installed only while the panel is open and taken down again on close, rather
    /// than living for the window's whole life, because an event monitor is global
    /// to the process and this one has nothing to do when there is nothing to
    /// dismiss.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            // A press in another window has a different origin, so converting it
            // into this window's coordinates would land somewhere arbitrary and
            // dismiss on a guess.
            guard event.window === self.fieldView?.window else { return event }
            let point = event.locationInWindow
            if self.contains(point, in: self.fieldView) || self.contains(point, in: self.dropdown) {
                return event
            }
            self.dismissForOutsideClick()
            // Returned rather than swallowed: the click belongs to whatever is
            // underneath, and this only gets the spotlight out of the way first.
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        guard let monitor = outsideClickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        outsideClickMonitor = nil
    }

    /// Closes the dropdown and gives up focus, so the field goes back to showing the
    /// page's address rather than sitting there looking editable and empty.
    private func dismissForOutsideClick() {
        close()
        fieldView?.window?.makeFirstResponder(nil)
    }

    private func contains(_ pointInWindow: NSPoint, in view: NSView?) -> Bool {
        guard let view else { return false }
        let local = view.convert(pointInWindow, from: nil)
        return view.bounds.contains(local)
    }

    private func refreshResults(scrollToSelection: Bool = false) {
        dropdown?.setResults(results, selectedID: selectedEntry?.id, scrollToSelection: scrollToSelection, onHover: { [weak self] entry in self?.hover(entry) }) { [weak self] entry in
            self?.choose(entry)
        }
    }

    /// Hovering a row makes it the active one, so the mouse and the arrow keys
    /// share a single selection. Guarded against the row already being active:
    /// rebuilding the hosted view re-fires the hover under a stationary mouse,
    /// and without this that would rebuild again, forever.
    private func hover(_ entry: HistoryFuzzyEntry) {
        guard selectedEntry?.id != entry.id else { return }
        selectedIndex = results.firstIndex(where: { $0.id == entry.id })
        refreshResults()
    }

    // MARK: - Selection

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = selectedIndex ?? (offset > 0 ? -1 : results.count)
        selectedIndex = min(max(current + offset, 0), results.count - 1)
        // The arrows pull the list with the selection; hover leaves the scroll
        // position alone for the mouse user to drive by hand.
        refreshResults(scrollToSelection: true)
    }

    @discardableResult
    func chooseSelected() -> Bool {
        guard let entry = selectedEntry else { return false }
        choose(entry)
        return true
    }

    private func choose(_ entry: HistoryFuzzyEntry) {
        guard let url = URL(string: entry.url) else {
            SystemBeep.play()
            return
        }
        // History rewrites the bar with its destination, showing where it is
        // going immediately. The search row does not: its destination is the
        // engine's URL, and the typed text it replaces is what a failed search
        // needs to keep for a retry. The navigation updates the bar on commit.
        // Set directly, not typed: this must repaint only, never re-query.
        if !entry.isSearchRow {
            fieldView?.textField.stringValue = entry.url
            fieldView?.updateClearButton()
        }
        close()
        onNavigate?(url)
    }

    /// Enter with no highlighted row: parse whatever is typed, exactly as before.
    private func submitTyped(_ text: String) {
        let engine = SettingsStore.shared.settings.search.engine()
        guard let url = AddressParser.url(from: text, searchEngine: engine) else { return }
        close()
        onNavigate?(url)
    }

    /// Dismissed when the field loses focus, so clicking into the page closes it.
    func fieldDidEndEditing() {
        guard isOpen else { return }
        close()
    }
}