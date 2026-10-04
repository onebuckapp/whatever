import AppKit
import SwiftUI

/// The dropdown that hangs below a `SpotlightField`.
///
/// Same width, same left and right edges, and the border continues the field's
/// rather than being drawn fresh: square top corners because the field's bottom
/// corners squared to meet it, rounded bottom corners at the same radius as the
/// field's. A 1pt separator across the seam.
///
/// Built here in AppKit rather than as SwiftUI because the seam has to be exact.
/// The field squares its own bottom corners to receive this panel, and a
/// `UIHostingView` between the two would put its own rounding and its own
/// background in that seam.
@MainActor
final class SpotlightDropdown: NSView {
    /// The field's radius and border, shared rather than restated, so the panel and
    /// the bar cannot drift apart.
    private static let cornerRadius = SpotlightField.cornerRadius
    private static let borderWidth: CGFloat = 1

    /// Where the fuzzy results go. Replaced wholesale per query, so it is a plain
    /// hosted view rather than something held onto.
    private var resultsView: NSHostingView<SpotlightResultsList>?

    /// The entries the hosted list is currently showing, by identity.
    ///
    /// Selection moves constantly — every hover crossing and every arrow press —
    /// and rebuilding the hosted view for that tore the whole list down per step:
    /// every row was recreated, the visit counts flickered, and the scroll offset
    /// reset. Entries and selection therefore update separately: new entries
    /// rebuild, a moved selection only retargets the existing list.
    private var shownEntryIDs: [HistoryFuzzyEntry.ID]?

    /// Deliberately no height callback. The panel sizes itself from the row count,
    /// which it has to do before the SwiftUI list has been laid out.

/// Installed once, at construction, and changed rather than replaced.
    ///
    /// Two height constraints on one view is not a stricter layout, it is an
    /// unsatisfiable one: AutoLayout breaks whichever it likes, and here it broke
    /// the pin to the bar's bottom edge instead, which put the panel over the search
    /// field rather than under it.
    /// Unused. The height is derived from the row count because the SwiftUI list
    /// has not been laid out when it has to be decided.
    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Grows to fit the rows, capped at the list's own maximum, so the panel never
    /// needs a scrollbar of its own and every result stays visible.
    func setHeight(_ height: CGFloat) {
        heightConstraint?.constant = height
    }

    /// - Note: Replaces the hosted list wholesale rather than assigning a new root to
///   the existing one. Assigning `rootView` re-measures the hosting view, which
///   resized the panel mid-query and left a stale height behind — the panel came
///   back 133pt tall for twelve results, with only three rows showing and no way to
///   reach the rest.
/// Empties the panel while it stays parented and hidden.
    ///
    /// Used on close rather than dropping the rows on the floor: a query that matched
    /// nothing has to leave an empty panel behind, and the hosted `ScrollView` is
    /// cheap to reuse when it will be filled again immediately.
    func clearResults() {
        resultsView?.removeFromSuperview()
        resultsView = nil
        shownEntryIDs = nil
        setHeight(0)
    }

    /// - Note: Replaces the hosted list wholesale rather than assigning a new root to
    ///   the existing one. Assigning `rootView` re-measures the hosting view, which
    ///   resized the panel mid-query and left a stale height behind — the panel came
    ///   back 133pt tall for twelve results, with only three rows showing and no way
    ///   to reach the rest.
    func setResults(_ entries: [HistoryFuzzyEntry], selectedID: HistoryFuzzyEntry.ID?, scrollToSelection: Bool, onHover: @escaping (HistoryFuzzyEntry) -> Void, onChoose: @escaping (HistoryFuzzyEntry) -> Void) {
        guard !entries.isEmpty else {
            clearResults()
            return
        }
        let ids = entries.map(\.id)
        if let hosted = resultsView, shownEntryIDs == ids {
            // Same rows, moved selection: retarget in place. Assigning a new root
            // lets SwiftUI reconcile — only the two rows whose highlight changed
            // re-render — instead of recreating the list. The height cannot move:
            // the row count is unchanged and the panel's own height constraint is
            // untouched.
            hosted.rootView = SpotlightResultsList(
                entries: entries,
                selectedID: selectedID,
                onChoose: onChoose,
                onHover: onHover,
                scrollToSelection: scrollToSelection
            )
            enforceOverlayScrollerSoon()
            return
        }
        let list = SpotlightResultsList(
            entries: entries,
            selectedID: selectedID,
            onChoose: onChoose,
            onHover: onHover,
            scrollToSelection: scrollToSelection
        )
        let hosted = NSHostingView(rootView: list)
        hosted.translatesAutoresizingMaskIntoConstraints = false
        resultsView?.removeFromSuperview()
        resultsView = hosted
        shownEntryIDs = ids
        addSubview(hosted)
        NSLayoutConstraint.activate([
            // Inset by the border so the list's own content cannot sit under it.
            hosted.topAnchor.constraint(equalTo: topAnchor),
            hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reportHeight(for: entries.count)
        enforceOverlayScrollerSoon()
    }

    /// Sizes the panel to its rows.
    ///
    /// Called from `setResults` before the SwiftUI list is laid out, so the height
    /// has to come from the row count rather than from measuring: at this point the
    /// hosted list still reports the height of its previous contents, and asking
    /// the view for its size gave 89pt for three 44pt rows.
    private func reportHeight(for count: Int) {
        setHeight(SpotlightResultsList.height(forRowCount: count) + Self.borderWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.cornerRadius
        let line = Self.borderWidth

        // The fill is inset by half the stroke so the border is not painted over
        // by it, which is what keeps the line exactly one pixel.
        let rect = NSRect(
            x: line / 2,
            y: line / 2,
            width: max(0, bounds.width - line),
            height: max(0, bounds.height - line)
        )
        // Square top corners meeting the bar's squared bottom edge; rounded bottom
        // corners at the bar's radius. No top edge of its own: the bar's bottom
        // border is the line between the two, and stroking a second one here plus
        // the separator that used to sit under it made the join three lines thick
        // with notches at each end.
        let fill = SpotlightField.outline(
            in: rect,
            topRadius: 0,
            bottomRadius: radius - line / 2
        )
        NSColor.controlBackgroundColor.setFill()
        fill.fill()
        NSColor.separatorColor.setStroke()
        let sides = SpotlightField.sidesPath(in: rect, bottomRadius: radius - line / 2)
        sides.lineWidth = line
        sides.stroke()
    }

    /// Forces the overlay scroller on the hosted list, on every layout.
    ///
    /// SwiftUI's `ScrollView` builds a real `NSScrollView` inside the hosting view,
    /// and here it comes out the legacy kind: a visible track that takes ~15pt
    /// from the rows even when nothing scrolls. The overlay kind draws no track at
    /// all — the knob floats over the rows — which is the transparent scrollbar the
    /// design calls for.
    override func layout() {
        super.layout()
        enforceOverlayScroller(in: self)
    }

    /// Re-applied on the next turn of the runloop after the hosted content lands.
    ///
    /// `layout` alone never catches the scroll view: SwiftUI builds it
    /// asynchronously after the hosting view is added, so enforcing during layout
    /// always ran before it existed — and nothing re-lays the panel out
    /// afterwards, since its size never changes. Every `setResults` schedules one
    /// of these, so a scroll view SwiftUI rebuilds or resets on a later body
    /// evaluation is re-caught on the next selection move at the latest.
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
                // Not autohiding: the knob stays visible, floating over the rows
                // with no track behind it.
                scroll.autohidesScrollers = false
                scroll.verticalScroller?.scrollerStyle = .overlay
            }
            enforceOverlayScroller(in: subview)
        }
    }
}

/// SwiftUI list of fuzzy hits, hosted inside `SpotlightDropdown`.
///
/// Rows are 44pt to match `HistorySettingsView.row`, which is where the metrics
/// came from, and six fit before the panel scrolls.
struct SpotlightResultsList: View {
    let entries: [HistoryFuzzyEntry]
    let selectedID: HistoryFuzzyEntry.ID?
    let onChoose: (HistoryFuzzyEntry) -> Void
    /// Hovering a row selects it: the mouse and the arrow keys share one active
    /// row rather than each painting their own.
    let onHover: (HistoryFuzzyEntry) -> Void
    /// Whether a moved selection pulls the list with it. True for the arrow keys,
    /// false for hover: the mouse user scrolls by hand, and having the list jump
    /// under a stationary cursor is exactly what that manual scroll is for.
    let scrollToSelection: Bool

    static let rowHeight: CGFloat = 44
    static let maximumVisibleRows = 6

    /// One place that decides how tall a given number of results is, so the AppKit
    /// panel sizing and the SwiftUI layout cannot drift apart.
    static func height(forRowCount count: Int) -> CGFloat {
        CGFloat(min(count, maximumVisibleRows)) * rowHeight
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        SpotlightResultRow(
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
                // Arrow-key navigation keeps the active row on screen: with twelve
                // results in a six-row panel the selection would otherwise walk off
                // the visible area silently. No anchor, so the list moves the
                // minimum distance to reveal the row — stepping between visible
                // rows does not move the scrollbar at all. Hover deliberately
                // does not scroll: the mouse user scrolls by hand.
                guard scrollToSelection, let newID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newID)
                }
            }
            // Overlay scroller: no track is drawn behind the knob and it does not reserve
            // any width, so the rows keep the panel's full width and nothing but the
            // knob itself ever appears. The default legacy scroller draws a visible
            // track and takes ~15pt from the content, which on a 460pt panel is a strip
            // of dead space down one side even when nothing is scrolling.
            .scrollIndicators(.visible)
            // Transparent: the panel behind paints the surface, and the floating knob
            // is the only thing this list contributes.
            .background(Color.clear)
            .frame(height: Self.height(forRowCount: entries.count))
        }
    }
}

/// One history row: title above, host below, matched characters picked out.
///
/// Both lines highlight independently because the core splits the match positions
/// across the two fields.
private struct SpotlightResultRow: View {
    let entry: HistoryFuzzyEntry
    let isSelected: Bool
    let onChoose: (HistoryFuzzyEntry) -> Void
    let onHover: (HistoryFuzzyEntry) -> Void

    /// The active row's wash: the accent colour, barely there. Solid accent would
    /// need inverted text to read on it; a wash this light keeps the normal text
    /// colours working, so hovering and arrowing land on the same look.
    private static let activeOpacity: CGFloat = 0.15

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                line(entry.title.isEmpty ? entry.url : entry.title,
                     ranges: entry.title.isEmpty ? entry.urlHighlight : entry.titleHighlight,
                     size: 12,
                     dim: false)
                line(entry.host.isEmpty ? entry.url : entry.host,
                      ranges: entry.host.isEmpty ? entry.urlHighlight : [],
                      size: 10,
                      dim: true)
            }
            Spacer(minLength: 8)
            if entry.visitCount > 1 {
                Text("\(entry.visitCount) visits")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: SpotlightResultsList.rowHeight)
        .background(
            // Square, edge to edge: the wash runs directly under the bar's bottom
            // border, and any rounding here would cut notches into the panel's
            // square top corners. Hover and the arrow keys share this one look.
            Rectangle()
                .fill(isSelected ? Color(nsColor: .controlAccentColor).opacity(Self.activeOpacity) : Color.clear)
        )
        .contentShape(Rectangle())
        // A gesture rather than a Button: a Button wants first responder, and the
        // address field has to keep receiving the arrow keys and Enter.
        .onTapGesture { onChoose(entry) }
        .onHover { hovering in
            guard hovering else { return }
            onHover(entry)
        }
    }

    /// One line with `ranges` picked out.
    ///
    /// Colours and fonts are set inside the `AttributedString` rather than with
    /// `.font` or `.foregroundStyle` on the `Text`, since a modifier like that is
    /// applied over the whole string and would flatten the highlight back to the
    /// line's own colour.
    private func line(_ text: String, ranges: [NSRange], size: CGFloat, dim: Bool) -> Text {
        var attributed = AttributedString(text)
        attributed.font = .system(size: size)
        attributed.foregroundColor = dim ? .secondary : .primary
        guard !ranges.isEmpty, !text.isEmpty else { return Text(attributed) }

        // Always accent, on every row: the active wash is barely there, so the
        // normal text colours keep working on it and hover and arrows land on the
        // same look. (Back when the wash was solid accent, the highlight had to go
        // white on the active row to read at all.)
        let highlight = Color(nsColor: .controlAccentColor)
        for range in ranges {
            guard let stringRange = Range(range, in: text),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed)
            else { continue }
            attributed[lower ..< upper].foregroundColor = highlight
            attributed[lower ..< upper].font = .system(size: size, weight: .bold)
        }
        return Text(attributed)
    }
}