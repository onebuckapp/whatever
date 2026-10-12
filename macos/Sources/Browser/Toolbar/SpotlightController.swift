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

    /// Finished "N visits" labels by entry id, for the rows the dropdown is
    /// showing. Resolved in one batch call per result set: per-row lookups
    /// would put an IPC round trip on every keystroke.
    private var visitLabels: [String: String] = [:]
    /// Entry ids the labels above were resolved for. Selection moves reuse
    /// them; new results re-resolve.
    private var labeledEntryIDs: [String] = []
    private var localeObserver: NSObjectProtocol?

    private var pendingSearch: Task<Void, Never>?
    /// The core's input-hint request in flight, if any. Undebounced — the
    /// call is pure computation with no disk touch — so the ghost tracks
    /// typing instead of trailing it by the history debounce.
    private var hintTask: Task<Void, Never>?
    /// The hint's answer for the text it was asked about: the pending
    /// action's destination, so Enter opens exactly what the ghost promised
    /// even where the address parser would decide differently (a dotted word
    /// with no real TLD searches rather than loading dead). Consumed on
    /// submit; only an exact text match counts.
    private var cachedHint: (text: String, url: URL)?
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
            self.queryChanged(field.textField.stringValue)
        }
        field.onMoveSelection = { [weak self] offset in self?.moveSelection(by: offset) }
        field.onTabThroughSelection = { [weak self] forward in
            self?.tabThroughSelection(forward: forward) ?? false
        }
        field.onDismiss = { [weak self] in self?.close() }
        // An open dropdown re-resolves its count labels in the new language;
        // a closed one has nothing to show, so it just drops the cache.
        localeObserver = NotificationCenter.default.addObserver(
            forName: .localizationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fieldView?.applyLanguage()
            self?.labeledEntryIDs = []
            self?.refreshResults()
        }
    }

    // MARK: - Querying

    /// The ghost and the history both answer the live text. The ghost goes
    /// out undebounced on every keystroke (the call is pure computation, so
    /// it tracks typing); history keeps its debounce below. A stale ghost
    /// clears up front and returns with the hint, so it can never name the
    /// previous keystroke's action.
    func queryChanged(_ text: String) {
        generation += 1
        let generation = self.generation
        pendingSearch?.cancel()
        hintTask?.cancel()
        fieldView?.setGhost(nil)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty means "most recent", not "nothing": clearing the field should still
        // offer somewhere to go. Below the minimum, nothing but the ghost — one
        // character is not a search, it is a prefix, and a dropdown of everything
        // for it is noise.
        guard !trimmed.isEmpty else {
            showMostRecent()
            return
        }
        requestHint(for: trimmed, generation: generation)
        guard trimmed.count >= Self.minimumQueryLength else {
            return
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

    /// Asks the core whether the live text navigates or searches, and paints
    /// the ghost from the answer. Generation-guarded like the history path:
    /// a hint landing after the next keystroke is for nobody.
    private func requestHint(for trimmed: String, generation: Int) {
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            guard let self else { return }
            let payload: Data
            do {
                payload = try await StoreClient.shared.spotlightHint(trimmed)
            } catch {
                return
            }
            guard !Task.isCancelled, generation == self.generation else { return }
            self.applyHint(payload, for: trimmed)
        }
    }

    /// The ghost and Enter destination for a hint answer: `Visit <address>`
    /// when the text navigates somewhere other than what is typed,
    /// `Search on <engine>` when it asks the engine, nothing when the
    /// destination is the text itself. Nil when no destination builds (a
    /// broken custom engine). Static and panel-free so the contract is
    /// testable without a field or a store round trip.
    nonisolated static func ghost(
        kind: String,
        trimmed: String,
        engine: ResolvedSearchEngine
    ) -> (text: String?, url: URL)? {
        if kind == "navigate" {
            guard let url = AddressParser.url(from: trimmed, searchEngine: engine) else { return nil }
            let destination = url.absoluteString
            guard destination != trimmed else { return (nil, url) }
            return (tr("Visit {address}", ctx: "Toolbar", args: ["address": destination]), url)
        }
        guard let url = engine.searchURL(for: trimmed) else { return nil }
        return (tr("Search on {name}", ctx: "Toolbar", args: ["name": engine.title]), url)
    }

    /// Paints a hint answer: caches the destination for Enter and shows the
    /// ghost, or stands both down when nothing builds. Generation-guarded by
    /// the caller.
    private func applyHint(_ payload: Data, for trimmed: String) {
        struct Hint: Decodable {
            var kind: String
        }
        guard let hint = try? JSONDecoder().decode(Hint.self, from: payload) else { return }
        let engine = SettingsStore.shared.settings.search.engine()
        guard let resolved = Self.ghost(kind: hint.kind, trimmed: trimmed, engine: engine) else {
            cachedHint = nil
            return
        }
        cachedHint = (trimmed, resolved.url)
        fieldView?.setGhost(resolved.text)
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
        // The bookmarked-URL set comes from the prewarmed cache: one pass
        // over a few hundred nodes, no store round trip on the keystroke
        // path. History rows get flagged here; bookmark-sourced rows arrive
        // already flagged and keep their flag through the blend.
        let bookmarkedURLs = Set(BookmarkStore.shared.nodes.values.compactMap { node in
            node.kind == .link ? node.url.map(BookmarkURL.normalized) : nil
        })
        let history = Self.markingBookmarked(entries, bookmarkedURLs: bookmarkedURLs)
        // Bookmarks blend with history under one ordering rather than
        // pinning a section of their own: a bookmarked daily page is already
        // represented by its high-visit history row, while a bookmark whose
        // history was cleared still surfaces on URL length alone. The live
        // text ranks a visited host it names above everything else.
        let live = fieldView?.textField.stringValue ?? ""
        let blended = Self.blend(
            history: history,
            bookmarks: bookmarkEntries(for: live),
            limit: Self.resultLimit,
            query: live
        )
        results = blended
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
        // No history is not no answer: the ghost still offers the typed
        // action, so the panel hides but the session stays alive for it.
        guard !results.isEmpty else {
            hidePanel()
            return
        }
        refreshResults()
        openPanel()
    }

    /// Bookmark hits for the live text, from the prewarmed cache: no store
    /// round trip on the keystroke path. Queries below the minimum match
    /// nothing, exactly like history.
    private func bookmarkEntries(for live: String) -> [HistoryFuzzyEntry] {
        let trimmed = live.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return [] }
        return BookmarkMatcher.hits(query: trimmed, nodes: Array(BookmarkStore.shared.nodes.values)).map {
            HistoryFuzzyEntry(
                bookmark: $0.node,
                score: $0.score,
                titlePositions: $0.titlePositions,
                urlPositions: $0.urlPositions
            )
        }
    }

    /// Flags rows whose URL is bookmarked, so the list can star them.
    /// Skips rows already flagged. Static and panel-free so the rule is
    /// testable without a field or any history.
    nonisolated static func markingBookmarked(
        _ entries: [HistoryFuzzyEntry],
        bookmarkedURLs: Set<String>
    ) -> [HistoryFuzzyEntry] {
        entries.map { entry in
            guard !entry.isBookmarked else { return entry }
            var copy = entry
            copy.isBookmarked = bookmarkedURLs.contains(BookmarkURL.normalized(entry.url))
            return copy
        }
    }

    /// The host with one leading `www.` dropped, lowercased, for prefix
    /// comparison against the query — the same rule the core ranks by, so a
    /// visited host the query names outranks everything else on both sides
    /// of the blend.
    nonisolated static func hostKey(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    /// One ordering over both sources: a visited host the query names first,
    /// then visits, then URL length, then score — the core's rule, applied
    /// here because bookmarks carry no visit count of their own. A URL in both
    /// is one row, and the history row wins it: it has the visits, the recency,
    /// and the same destination. Duplicate bookmarks (one page filed in two
    /// folders) collapse the same way. Static and panel-free so the rule is
    /// testable without a field or any history.
    nonisolated static func blend(
        history: [HistoryFuzzyEntry],
        bookmarks: [HistoryFuzzyEntry],
        limit: Int,
        query: String = ""
    ) -> [HistoryFuzzyEntry] {
        var seen = Set(history.map { BookmarkURL.normalized($0.url) })
        var merged = history
        merged.reserveCapacity(history.count + bookmarks.count)
        for bookmark in bookmarks {
            let key = BookmarkURL.normalized(bookmark.url)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(bookmark)
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        merged.sort {
            let boost0 = !needle.isEmpty && hostKey($0.host).hasPrefix(needle)
            let boost1 = !needle.isEmpty && hostKey($1.host).hasPrefix(needle)
            if boost0 != boost1 { return boost0 && !boost1 }
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            if $0.url.count != $1.url.count { return $0.url.count < $1.url.count }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.url < $1.url
        }
        return Array(merged.prefix(max(0, limit)))
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
        dropdown.onHoverExit = { [weak self] in self?.clearHoverSelection() }
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
        hintTask?.cancel()
        hintTask = nil
        generation += 1
        results = []
        selectedIndex = nil
        cachedHint = nil
        fieldView?.setGhost(nil)
        hidePanel()
    }

    /// Takes the panel down without ending the session: history came back
    /// empty but the ghost still offers the typed action, so the highlight
    /// state resets while the hint stands.
    private func hidePanel() {
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
        let ids = results.map(\.id)
        if ids != labeledEntryIDs {
            // New rows: show first with whatever labels stand, then re-enter
            // once the batch lands. Selection-only moves skip this: their ids
            // match and the cached labels are current.
            Task { [weak self] in
                await self?.resolveVisitLabels(for: ids, scrollToSelection: scrollToSelection)
            }
        }
        dropdown?.setResults(results, selectedID: selectedEntry?.id, scrollToSelection: scrollToSelection, visitLabels: visitLabels, onHover: { [weak self] entry in self?.hover(entry) }) { [weak self] entry in
            self?.choose(entry)
        }
    }

    /// One batch call resolves every visible "N visits" label in the row's
    /// own words for every count, then re-enters `refreshResults`, whose id
    /// check terminates. Stale answers (the list moved on mid-flight) are
    /// dropped, and an empty batch keeps English fallbacks in the rows.
    private func resolveVisitLabels(for ids: [String], scrollToSelection: Bool) async {
        let counted = results.filter { $0.visitCount > 1 }
        var labels: [String: String] = [:]
        if !counted.isEmpty {
            let items = counted.map { entry in
                LocaleItem("one visit", plural: "{n} visits", n: entry.visitCount)
            }
            let texts = await Localization.batch(items)
            for (offset, entry) in counted.enumerated() where offset < texts.count {
                labels[entry.id] = texts[offset]
            }
        }
        guard results.map(\.id) == ids else { return }
        visitLabels = labels
        labeledEntryIDs = ids
        refreshResults(scrollToSelection: scrollToSelection)
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

    /// Pointer left the panel: drop the selection so Enter submits the typed
    /// text rather than opening the row the cursor happened to leave on. Safe
    /// for keyboard-placed highlights too: those rewrite the field with the
    /// row's URL on the way in, so submitting the text opens the same place.
    private func clearHoverSelection() {
        guard selectedIndex != nil else { return }
        selectedIndex = nil
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
        reflectSelectionInField()
    }

    /// Walks the selection with wraparound for Tab (`forward`) and
    /// Shift+Tab: past the last row back to the first, past the first to
    /// the last. Arrows deliberately do not wrap (see `moveSelection`).
    /// Returns whether the key was consumed: with no rows to walk, Tab
    /// keeps its normal meaning and leaves the field.
    @discardableResult
    func tabThroughSelection(forward: Bool) -> Bool {
        guard let next = Self.nextWrappingIndex(
            current: selectedIndex,
            count: results.count,
            forward: forward
        ) else {
            return false
        }
        selectedIndex = next
        // Like the arrows: the list follows the selection.
        refreshResults(scrollToSelection: true)
        reflectSelectionInField()
        return true
    }

    /// Next index walking `count` rows with wraparound, or nil when there
    /// is nothing to walk. No selection starts before the first row going
    /// forward and on it going backward, so Tab opens on the first row and
    /// Shift+Tab on the last. Static so the rule is testable without a
    /// panel, a field, or any history.
    static func nextWrappingIndex(current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        let base = current ?? (forward ? -1 : 0)
        if forward {
            return (base + 1) % count
        }
        return (base - 1 + count) % count
    }

    /// Mirrors the highlighted row into the field: the input shows the row's
    /// URL, stays focused, and selects it all, so typing replaces it and
    /// Enter opens it. Set directly, never typed: this repaints only and must
    /// not re-query. The ghost clears with it: it named the typed text, not
    /// the filled URL. Mouse hover highlights without filling — filling follows
    /// the keyboard alone.
    private func reflectSelectionInField() {
        guard let fieldView, let entry = selectedEntry else { return }
        fieldView.textField.stringValue = Self.fieldText(for: entry)
        fieldView.setGhost(nil)
        fieldView.updateClearButton()
        // The keys arrive through the field editor, so it holds focus by
        // construction; re-asserted anyway, because a future dropdown change
        // must never strand the caret outside the input it just filled.
        if let window = fieldView.window, window.firstResponder !== fieldView.textField {
            _ = window.makeFirstResponder(fieldView.textField)
        }
        fieldView.textField.currentEditor()?.selectAll(nil)
    }

    /// The field text for a highlighted row: the row's URL. Static so the
    /// rule is testable without a panel, a field, or any history.
    static func fieldText(for entry: HistoryFuzzyEntry) -> String {
        entry.url
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
        // going immediately. Set directly, not typed: this must repaint only,
        // never re-query. The navigation updates the bar on commit.
        fieldView?.textField.stringValue = entry.url
        fieldView?.updateClearButton()
        close()
        onNavigate?(url)
    }

    /// Enter with no highlighted row: the hint's cached destination when it
    /// answers for exactly this text, the address parser otherwise. The cache
    /// is what keeps Enter honest where the parser and the core disagree — a
    /// dotted word with no real TLD searches rather than loading dead — and
    /// a text that moved on since the hint landed parses fresh, as before.
    private func submitTyped(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedHint, cachedHint.text == trimmed {
            let url = cachedHint.url
            close()
            onNavigate?(url)
            return
        }
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