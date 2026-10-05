import AppKit
import MijickPopups
import SwiftUI

/// The settings card: a fixed sidebar beside a scrolling detail pane.
///
/// Styled exactly like the QR card — same backdrop opacity, corner radius, two
/// shadows, and vertical padding for shadow room — so the two read as one family
/// of dialogs. The consuming tap gesture matters as much as the looks: without it
/// a click on empty card space falls through to Mijick's tap-outside layer and
/// closes the dialog the user was trying to click inside.
struct SettingsModalPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    let section: SettingsSection

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.black.opacity(0.38))
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            SettingsModalCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    /// Hands off to the card rather than hosting the layout here.
    ///
    /// The section being shown has to change while the card is up, and this struct
    /// cannot hold that state: Mijick presents one popup value and the struct has
    /// to stay `Sendable`, so its `section` is fixed for the popup's whole life.
    /// `SettingsModalCard` is an ordinary view and can own the selection.
    var body: some View {
        SettingsModalCard(stackID: stackID, popupID: popupID, section: section)
    }
}

/// The card itself: a fixed sidebar beside a scrolling detail pane.
///
/// Styled exactly like the QR card — same backdrop opacity, corner radius, two
/// shadows, and vertical padding for shadow room — so the two read as one family
/// of dialogs. The consuming tap gesture matters as much as the looks: without it
/// a click on empty card space falls through to Mijick's tap-outside layer and
/// closes the dialog the user was trying to click inside.
private struct SettingsModalCard: View {
    /// The optical left edge that the heading and every row's first glyph sit on,
    /// measured from the card's own edge.
    ///
    /// The sidebar's background is flush with the card's rounded left edge, so the
    /// glyphs need a real inset from it. This is that inset, and it is the number
    /// the text is aligned to.
    private static let textInset: CGFloat = 18

    /// Inset of a row from the sidebar's edges, which is the margin the selection
    /// pill ends up with.
    ///
    /// A row's padding is applied before its background, so the highlight covers
    /// that padding as well and ran the full width of the sidebar, flush against
    /// both edges. Insetting the list is what gives the pill a margin; the row's
    /// own padding then hands the glyph back to `textInset`.
    private static let listInset: CGFloat = 8

    /// Padding inside a row, so `listInset` plus this lands on `textInset`.
    ///
    /// Derived rather than written down, because the heading and the rows share
    /// this one value and are only aligned to each other while it stays in step
    /// with the list inset.
    private static var rowInset: CGFloat { textInset - listInset }

    let stackID: PopupStackID
    let popupID: String

    /// Which pane the card opened on. The sidebar moves the selection from here.
    @State private var selected: SettingsSection

    /// Sections whose pane is currently in the tree, in the order they were first
    /// opened.
    ///
    /// Panes are kept mounted and switched with `hidden` rather than replaced, and
    /// this is the whole reason. Measured in the running app: a switch that builds
    /// the pane costs 240 to 350ms of main-thread work, and a switch to the pane
    /// already showing costs 0.08ms. The state change itself is free (0.03ms), and
    /// the card's two large shadows turned out to be irrelevant to it, so the cost
    /// is entirely SwiftUI building the pane's subtree, paid again on every click.
    ///
    /// It only ever grows while the modal is open. A section is mounted the first
    /// time it is opened and every later visit is a visibility toggle, which also
    /// keeps each pane's `@State`, so History and Bookmarks do not refetch and
    /// reshow their spinner.
    ///
    /// Two things follow from keeping a pane alive that used to be reset on every
    /// switch, both deliberate: a pane keeps its scroll offset, so returning to a
    /// long section lands where it was left, and its fetched rows are not reloaded
    /// until the modal is closed.
    @State private var mounted: [SettingsSection]

    init(stackID: PopupStackID, popupID: String, section: SettingsSection) {
        self.stackID = stackID
        self.popupID = popupID
        _selected = State(initialValue: section)
        _mounted = State(initialValue: [section])
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            // No scroll view wraps the panes. A vertical one proposes nil height, and a
            // pane that wants to fill the card vertically, which every centered
            // placeholder does, cannot fill a proposal of nil: it collapses to its
            // ideal height and sits at the top. Scrolling belongs to the panes that
            // need it instead, so a short pane gets the card's real height and a
            // tall one still scrolls.
            //
            // Every pane the user has opened is stacked, and only the selected one
            // is visible, so a return visit is a visibility toggle instead of a
            // rebuild. Iterating `mounted` is also what pins each pane's position
            // in the tree, and that position is what preserves its `@State` and its
            // scroll offset across re-evaluations.
            ZStack {
                ForEach(mounted, id: \.self) { entry in
                    SettingsDetailView.view(for: entry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(entry == selected ? 1 : 0)
                        // `hidden()` takes no argument, so visibility is
                        // opacity plus hit-testing. The second half is not
                        // optional: an invisible pane that still took clicks
                        // would swallow every click on the pane below it.
                        .allowsHitTesting(entry == selected)
                        .accessibilityHidden(entry != selected)
                }
            }
        }
        .frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
        // Mijick masks the whole popup to its measured bounds, so the shadows
        // need transparent room around the card. Symmetric, so the card itself
        // stays centered.
        .padding(.vertical, 88)
        .onTapGesture {}
        .onExitCommand {
            Task {
                await PopupStack.dismissPopup(popupID, popupStackID: stackID)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, Self.rowInset)
                .padding(.top, 14)
                .padding(.bottom, 8)
            ForEach(SettingsSection.allCases) { entry in
                row(entry)
            }
            Spacer(minLength: 0)
        }
        // Before the frame, so the frame still fixes the sidebar's outer width and
        // the rows are laid out inside the inset. Padding after it would widen the
        // sidebar to 212 and drag the divider out with it.
        .padding(.horizontal, Self.listInset)
        .frame(width: 196)
        .padding(.bottom, 10)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// A sidebar row that switches the detail pane.
    ///
    /// Deliberately does *not* dismiss the card. Picking a section is navigation
    /// inside the dialog; closing it on every click meant the sidebar could only
    /// ever be used to reopen the modal on a different pane, which is not what a
    /// sidebar is for.
    private func row(_ entry: SettingsSection) -> some View {
        let isSelected = entry == selected
        return Button {
            // Mount before selecting, so the pane is built in the same update
            // that shows it rather than one frame later.
            if !mounted.contains(entry) {
                mounted.append(entry)
            }
            selected = entry
        } label: {
            HStack(spacing: 8) {
                Group {
                    if entry == .rssFeeds, let rss = NSImage(named: "RSS") {
                        Image(nsImage: rss)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: entry.symbol)
                    }
                }
                .frame(width: 16)
                Text(entry.title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, Self.rowInset)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Root view hosted in the window content.
///
/// Fills the window so the card centres over the whole window and tap-outside
/// covers the page, matching how the noise card and the QR card behave.
struct SettingsModalRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let section: SettingsSection

    var body: some View {
        Color.clear
            .registerPopups(id: stackID) { config in
                config.center { popup in
                    popup
                        .backgroundColor(.clear)
                        .cornerRadius(20)
                        .overlayColor(.black.opacity(0.38))
                        .tapOutsideToDismissPopup(true)
                }
            }
            .task {
                await SettingsModalPopup(
                    stackID: stackID,
                    popupID: popupID,
                    section: section
                )
                .present(popupStackID: stackID)
            }
    }
}

/// Routes Mijick's dismissal callback back to the presenter that owns the
/// hosting view. Popup structs must stay `Sendable`, so they cannot hold the
/// presenter directly.
@MainActor
final class SettingsModalCoordinator {
    static let shared = SettingsModalCoordinator()

    private var dismissHandlers: [String: () -> Void] = [:]

    func register(id: String, handler: @escaping () -> Void) {
        dismissHandlers[id] = handler
    }

    func popupDidDismiss(id: String) {
        dismissHandlers.removeValue(forKey: id)?()
    }
}

/// Bridges the window to Mijick/Popups for the settings card.
///
/// One presenter per window. The window owns the modal's lifetime, so tab
/// switches and layout changes do not need to dismiss it the way the QR card
/// does, and Escape is the only host-side dismissal.
@MainActor
final class SettingsModalPresenter {
    /// How far the pointer may move between press and release while the
    /// release still counts as the click that dismisses the card.
    ///
    /// Past this the gesture was a drag, not a click, and its release must
    /// not reach Mijick's tap-outside layer.
    private static let backdropClickSlop: CGFloat = 6

    private weak var container: NSView?
    private var hostingView: NSHostingView<SettingsModalRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?

    /// Swallows the release that ends a backdrop drag, so press-and-drag on
    /// the dimmed area cannot dismiss the card the way a clean click does.
    ///
    /// Mijick's tap-outside fires on release without checking how the pointer
    /// got there, which is why this presenter watches press and release
    /// itself. Only releases are ever held back, and only when the press
    /// began on the backdrop: anything starting on the card (scrolling a
    /// pane, dragging a selection) passes through untouched, because the
    /// card may be mid-gesture and waiting for that release.
    private var backdropDragMonitor: Any?

    /// Screen position of a press that began on the backdrop, while its
    /// release is still outstanding. Nil when the press began on the card
    /// (or when no button is down), in which case releases pass through.
    private var backdropPressPoint: NSPoint?
    private var onDidDismiss: (() -> Void)?

    init(container: NSView, onDidDismiss: (() -> Void)? = nil) {
        self.container = container
        self.onDidDismiss = onDidDismiss
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    /// Opens the card on `section`, or does nothing if it is already open.
    ///
    /// Re-opening while it is up would stack a second card on the same window,
    /// and Mijick does not collapse two popups of the same id.
    func present(section: SettingsSection = .general) {
        guard let container, container.window != nil, !isPresented else { return }
        resetForReuse()

        let stackID = PopupStackID(rawValue: "settings-\(UUID().uuidString)")
        let popupID = "settings"
        let root = SettingsModalRootView(stackID: stackID, popupID: popupID, section: section)
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.hostingView = hostingView
        self.stackID = stackID
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                Task { @MainActor in
                    self.dismiss()
                }
                return nil
            }
            return event
        }
        backdropDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            // Local monitors run on the main thread during event dispatch.
            return MainActor.assumeIsolated { self.filterBackdropDrag(event) }
        }
        SettingsModalCoordinator.shared.register(id: popupID) { [weak self] in
            self?.tearDown()
        }
    }

    func dismiss() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        tearDown()
    }

    /// Single teardown path, whether dismissal came from Escape, from
    /// Mijick's tap-outside layer, or from the owner.
    private func tearDown() {
        resetForReuse()
        let notify = onDidDismiss
        onDidDismiss = nil
        notify?()
    }

    /// Holds back the release that ends a drag which began on the backdrop.
    ///
    /// A clean click passes through and dismisses the card exactly as before.
    /// Anything else (no armed press, or a release near its press) is also a
    /// pass-through; only a release far from a backdrop press is swallowed.
    private func filterBackdropDrag(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            // Screen coordinates, so a window move mid-gesture cannot skew
            // the distance measured at release time.
            backdropPressPoint = pressIsOnBackdrop(event) ? NSEvent.mouseLocation : nil
            return event
        case .leftMouseUp:
            defer { backdropPressPoint = nil }
            guard let press = backdropPressPoint else { return event }
            let release = NSEvent.mouseLocation
            let moved = hypot(release.x - press.x, release.y - press.y)
            return moved > Self.backdropClickSlop ? nil : event
        default:
            return event
        }
    }

    /// Whether a press landed on the dimmed backdrop rather than the card.
    ///
    /// The card's hit box is its 720 by 520 frame plus the 88pt of shadow
    /// room above and below it, which is inside the card's tap area and
    /// looks like backdrop. Centered in the host, which fills the container.
    /// Expanded slightly, so a press on the boundary keeps today's behavior
    /// instead of joining the drag guard.
    private func pressIsOnBackdrop(_ event: NSEvent) -> Bool {
        guard let container else { return false }
        let point = container.convert(event.locationInWindow, from: nil)
        let bounds = container.bounds
        let box = NSRect(
            x: (bounds.width - 736) / 2,
            y: (bounds.height - 712) / 2,
            width: 736,
            height: 712
        )
        return !box.contains(point)
    }

    /// Drops the host without notifying the owner, so a re-present cannot clear
    /// the owner's reference to this presenter mid-present.
    private func resetForReuse() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let backdropDragMonitor {
            NSEvent.removeMonitor(backdropDragMonitor)
            self.backdropDragMonitor = nil
        }
        backdropPressPoint = nil
        hostingView?.removeFromSuperview()
        hostingView = nil
        stackID = nil
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        if let backdropDragMonitor {
            NSEvent.removeMonitor(backdropDragMonitor)
        }
    }
}