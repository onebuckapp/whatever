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

/// One row of a long-press history menu: the address and its position in
/// the tab's list. The title lands after opening (see `titleMap`): rows
/// show immediately with a host fallback rather than waiting on it.
struct HistoryMenuEntry: Identifiable {
    /// The tab-list index, stable across title refreshes, so a selection
    /// placed before the titles land still names the same row after.
    var id: Int { index }
    let url: URL
    let index: Int
    var title: String = ""
    var favicon: NSImage?

    /// The title line: the recorded page title, the host when the page
    /// never had one (or the store only recorded the address itself),
    /// never a duplicate of the address line below it.
    var displayTitle: String {
        HistoryMenuController.displayTitle(recorded: title, for: url)
    }
}

/// Owns the long-press history panel: its rows, its selection, and its
/// dismissal. The toolbar controller only says "show these entries under
/// this button" and takes the chosen list index back.
@MainActor
final class HistoryMenuController {
    private var panel: HistoryMenuDropdown?
    private var entries: [HistoryMenuEntry] = []
    private var selectedID: HistoryMenuEntry.ID?
    private var onChoose: ((Int) -> Void)?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var titleTask: Task<Void, Never>?
    private var generation = 0

    var isOpen: Bool { panel?.superview != nil }

    /// Shows the tab's back (or forward) entries in a floating panel hung
    /// below `button`: favicon, title, and address per row, nearest entry
    /// first. Choosing a row jumps the tab straight there.
    func show(
        entries: [HistoryMenuEntry],
        anchoredTo button: NSView,
        in container: NSView,
        onChoose: @escaping (Int) -> Void
    ) {
        dismiss()
        generation += 1
        guard !entries.isEmpty else { return }
        self.entries = entries
        self.onChoose = onChoose

        let width = min(
            HistoryMenuList.panelWidth,
            max(160, container.bounds.width - 16)
        )
        let height = HistoryMenuList.height(forRowCount: entries.count)
            + HistoryMenuDropdown.borderWidth
        // The button is not flipped, so below its bottom edge with a small
        // gap; left-aligned, clamped into the window.
        let anchor = container.convert(button.bounds, from: button)
        let origin = NSPoint(
            x: min(
                max(8, anchor.minX),
                max(8, container.bounds.width - 8 - width)
            ),
            y: anchor.minY - HistoryMenuDropdown.gap - height
        )
        let panel = HistoryMenuDropdown()
        panel.frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.onHoverExit = { [weak self] in self?.clearHoverSelection() }
        container.addSubview(panel, positioned: .above, relativeTo: nil)
        self.panel = panel
        refresh(scrollToSelection: false)
        installMonitors()
        resolveTitles()
    }

    func dismiss() {
        generation += 1
        titleTask?.cancel()
        titleTask = nil
        entries = []
        selectedID = nil
        onChoose = nil
        removeMonitors()
        panel?.removeFromSuperview()
        panel = nil
    }

    // MARK: - Rows

    /// Page titles by address, from one recent-history listing: exact
    /// addresses first, normalized forms beside them, so a recorded row
    /// meets its tab entry however the two spell trailing slashes,
    /// fragments, or case. Static so the merge is testable without a
    /// store round trip.
    nonisolated static func titleMap(from payload: Data) -> [String: String] {
        var map: [String: String] = [:]
        for entry in HistoryEntry.decodeList(payload) {
            guard !entry.title.isEmpty else { continue }
            map[entry.url] = entry.title
            let folded = BookmarkURL.normalized(entry.url)
            if map[folded] == nil {
                map[folded] = entry.title
            }
        }
        return map
    }

    /// The title line for a recorded title and its address: the title
    /// itself, unless there is none or it just repeats the address (the
    /// store records the address as the title when the page had none),
    /// in which case the host. Static so the rule is testable without a
    /// panel.
    nonisolated static func displayTitle(recorded title: String, for url: URL) -> String {
        guard !title.isEmpty, title != url.absoluteString else {
            return url.host ?? url.absoluteString
        }
        return title
    }

    /// Titles arrive after the rows are already showing: one listing,
    /// matched by address, then the list repaints in place. A newer
    /// opening (or a dismissal mid-flight) drops the answer.
    private func resolveTitles() {
        titleTask?.cancel()
        let generation = self.generation
        let wanted = entries.map(\.url)
        titleTask = Task { [weak self] in
            guard let payload = try? await StoreClient.shared.recentHistory(limit: 200) else { return }
            guard !Task.isCancelled else { return }
            let map = Self.titleMap(from: payload)
            guard let self, generation == self.generation, self.isOpen,
                  self.entries.map(\.url) == wanted
            else { return }
            self.entries = self.entries.map { entry in
                var copy = entry
                copy.title = map[entry.url.absoluteString]
                    ?? map[BookmarkURL.normalized(entry.url)]
                    ?? ""
                return copy
            }
            self.refresh(scrollToSelection: false)
        }
    }

    private func refresh(scrollToSelection: Bool) {
        panel?.setEntries(
            entries,
            selectedID: selectedID,
            scrollToSelection: scrollToSelection
        )
    }

    // MARK: - Selection

    private func choose(_ index: Int) {
        let callback = onChoose
        dismiss()
        callback?(index)
    }

    func moveSelection(by offset: Int) {
        guard !entries.isEmpty else { return }
        let current = selectedID.flatMap { id in entries.firstIndex(where: { $0.id == id }) }
            ?? (offset > 0 ? -1 : entries.count)
        let next = min(max(current + offset, 0), entries.count - 1)
        selectedID = entries[next].id
        // The arrows pull the list with the selection; hover leaves the
        // scroll position alone for the mouse user to drive by hand.
        refresh(scrollToSelection: true)
    }

    private func hover(_ index: Int) {
        guard selectedID != index else { return }
        selectedID = index
        refresh(scrollToSelection: false)
    }

    /// Pointer left the panel: drop the selection so Enter cannot open a
    /// row the cursor happened to leave on.
    private func clearHoverSelection() {
        guard selectedID != nil else { return }
        selectedID = nil
        refresh(scrollToSelection: false)
    }

    // MARK: - Dismissal

    /// Whether text is being edited somewhere: arrows and Enter belong to
    /// it, not to the panel. The panel can open while the address field
    /// holds focus (buttons never take focus), and stealing its keys
    /// would break typing to move a menu selection.
    private func isEditingText() -> Bool {
        panel?.window?.firstResponder is NSTextView
    }

    private func installMonitors() {
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] event in
            guard let self, self.isOpen else { return event }
            guard event.window === self.panel?.window else { return event }
            let point = event.locationInWindow
            if let panel = self.panel,
               panel.bounds.contains(panel.convert(point, from: nil))
            {
                return event
            }
            // Returned, not swallowed: the press belongs to whatever is
            // underneath, and this only gets the panel out of the way
            // first — including a press on the anchor button, whose click
            // then steps back/forward normally.
            self.dismiss()
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            switch event.keyCode {
            case 53: // Escape always closes the panel.
                self.dismiss()
                return nil
            case 125, 126: // Down, up walk the rows — unless text is editing.
                guard !self.isEditingText() else { return event }
                self.moveSelection(by: event.keyCode == 125 ? 1 : -1)
                return nil
            case 36, 76: // Enter opens the active row.
                guard !self.isEditingText() else { return event }
                // With no row active the key passes through rather than
                // dying on an open panel.
                guard let selectedID = self.selectedID else { return event }
                self.choose(selectedID)
                return nil
            default:
                return event
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel?.window,
            queue: .main
        ) { [weak self] _ in
            self?.dismiss()
        }
        panel?.onChoose = { [weak self] index in self?.choose(index) }
        panel?.onHover = { [weak self] index in self?.hover(index) }
    }

    private func removeMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}

/// The floating history panel: fully rounded with a border and a soft
/// shadow, hanging below a navigation button rather than joining any
/// chrome the way the spotlight dropdown joins its field.
///
/// Built in AppKit hosting SwiftUI, like `SpotlightDropdown`: the rows
/// are a SwiftUI list, the surface, border, and shadow are drawn here so
/// one radius owns both.
@MainActor
final class HistoryMenuDropdown: NSView {
    /// The gap between the button's bottom edge and the panel's top.
    static let gap: CGFloat = 4
    /// Fully rounded on all four corners: nothing squares off to meet.
    static let cornerRadius: CGFloat = 10
    static let borderWidth: CGFloat = 1

    /// The entries the hosted list is currently showing, by identity, so
    /// a moved selection retargets the list instead of rebuilding it and
    /// title refreshes land without losing the highlight or the scroll.
    private var shownEntryIDs: [HistoryMenuEntry.ID]?
    private var resultsView: NSHostingView<HistoryMenuList>?

    /// Fires when the pointer leaves the panel, so a hover-placed
    /// highlight does not stick around for Enter after the mouse is gone.
    var onHoverExit: (() -> Void)?
    var onChoose: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -3)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTracking == nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseExited(with event: NSEvent) {
        onHoverExit?()
    }

    /// Shows `entries`, rebuilding the hosted list only when the rows
    /// themselves changed. Assigning a new root lets SwiftUI reconcile —
    /// only the rows whose highlight or title changed re-render — instead
    /// of recreating the list and resetting its scroll.
    func setEntries(
        _ entries: [HistoryMenuEntry],
        selectedID: HistoryMenuEntry.ID?,
        scrollToSelection: Bool
    ) {
        guard !entries.isEmpty else { return }
        let ids = entries.map(\.id)
        if let hosted = resultsView, shownEntryIDs == ids {
            hosted.rootView = HistoryMenuList(
                entries: entries,
                selectedID: selectedID,
                scrollToSelection: scrollToSelection,
                onChoose: { [weak self] in self?.onChoose?($0) },
                onHover: { [weak self] in self?.onHover?($0) }
            )
            enforceOverlayScrollerSoon()
            return
        }
        let list = HistoryMenuList(
            entries: entries,
            selectedID: selectedID,
            scrollToSelection: scrollToSelection,
            onChoose: { [weak self] in self?.onChoose?($0) },
            onHover: { [weak self] in self?.onHover?($0) }
        )
        // Clipped to the panel's rounding, so scrolled rows and the
        // selection wash slide under the rounded corners instead of
        // poking square corners past them.
        let hosted = NSHostingView(rootView: list)
        hosted.translatesAutoresizingMaskIntoConstraints = false
        // Content must never size the panel: the rows fit whatever width
        // the frame computed, and a long row's intrinsic width reaching
        // out would resize the panel under the button.
        hosted.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hosted.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resultsView?.removeFromSuperview()
        resultsView = hosted
        shownEntryIDs = ids
        addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: topAnchor),
            hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        enforceOverlayScrollerSoon()
    }

    override func draw(_ dirtyRect: NSRect) {
        let line = Self.borderWidth
        let rect = NSRect(
            x: line / 2,
            y: line / 2,
            width: max(0, bounds.width - line),
            height: max(0, bounds.height - line)
        )
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Self.cornerRadius - line / 2,
            yRadius: Self.cornerRadius - line / 2
        )
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = line
        path.stroke()
    }

    override func layout() {
        super.layout()
        // The compositor's shadow follows the rounded surface rather than
        // the frame, and tracks resizes with it.
        layer?.shadowPath = NSBezierPath(
            roundedRect: bounds,
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        ).cgPath
        enforceOverlayScroller(in: self)
    }

    /// Forces the overlay scroller on the hosted list: SwiftUI's
    /// `ScrollView` builds the legacy kind here, whose visible track
    /// would take ~15pt from the rows even when nothing scrolls.
    /// Re-applied on the next runloop turn after content lands, because
    /// SwiftUI builds the scroll view asynchronously after the hosting
    /// view is added. (Twin of the enforcer in `SpotlightDropdown`.)
    private func enforceOverlayScrollerSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enforceOverlayScroller(in: self)
        }
    }

    private func enforceOverlayScroller(in view: NSView) {
        for subview in view.subviews {
            if let scroll = subview as? NSScrollView {
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = false
                scroll.verticalScroller?.scrollerStyle = .overlay
            }
            enforceOverlayScroller(in: subview)
        }
    }
}

/// The list of history rows, hosted inside `HistoryMenuDropdown`.
///
/// Rows match the history rows elsewhere (44pt, title over address) with
/// a favicon up front. The panel never grows past 350pt: seven rows show
/// (7 × 44 = 308) and longer histories scroll inside it.
struct HistoryMenuList: View {
    static let rowHeight: CGFloat = 44
    static let maximumVisibleRows = 7
    /// The 350pt cap, as rows: seven full rows show and the list scrolls
    /// past them rather than growing the panel.
    static let maximumHeight: CGFloat = 350
    static let panelWidth: CGFloat = 320

    /// One place that decides how tall a given number of rows is, so the
    /// controller's frame and this layout cannot drift apart.
    static func height(forRowCount count: Int) -> CGFloat {
        min(CGFloat(min(count, maximumVisibleRows)) * rowHeight, maximumHeight)
    }

    let entries: [HistoryMenuEntry]
    let selectedID: HistoryMenuEntry.ID?
    /// Whether a moved selection pulls the list with it. True for the
    /// arrow keys, false for hover: the mouse user scrolls by hand.
    let scrollToSelection: Bool
    let onChoose: (Int) -> Void
    let onHover: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HistoryMenuRow(
                            entry: entry,
                            isSelected: entry.id == selectedID,
                            onChoose: onChoose,
                            onHover: onHover
                        )
                        .id(entry.id)
                    }
                }
            }
            .onChange(of: selectedID) { _, newID in
                guard scrollToSelection, let newID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newID)
                }
            }
            .scrollIndicators(.visible)
            .background(Color.clear)
            .frame(height: Self.height(forRowCount: entries.count))
        }
        // Clipped to the panel's rounding, so scrolled rows and the
        // selection wash slide under the rounded corners instead of
        // poking square corners past them.
        .clipShape(RoundedRectangle(cornerRadius: HistoryMenuDropdown.cornerRadius))
    }
}

/// One history row: favicon, title above, address below.
///
/// Both lines truncate rather than grow: the rows fit the panel's width,
/// never the other way round.
private struct HistoryMenuRow: View {
    let entry: HistoryMenuEntry
    let isSelected: Bool
    let onChoose: (Int) -> Void
    let onHover: (Int) -> Void

    /// The active row's wash: the accent colour, barely there, shared with
    /// the spotlight rows so hover and arrows land on the same look
    /// everywhere.
    private static let activeOpacity: CGFloat = 0.15

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = entry.favicon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    // The tab strip's globe: every page starts on it and
                    // pages with no icon stay on it.
                    Image(systemName: "globe")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.url.absoluteString)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: HistoryMenuList.rowHeight)
        .background(
            Rectangle()
                .fill(isSelected ? Color(nsColor: .controlAccentColor).opacity(Self.activeOpacity) : Color.clear)
        )
        .contentShape(Rectangle())
        // A gesture rather than a Button: a Button wants first responder,
        // and focus must stay wherever it was when the panel opened.
        .onTapGesture { onChoose(entry.index) }
        .onHover { hovering in
            guard hovering else { return }
            onHover(entry.index)
        }
    }
}
