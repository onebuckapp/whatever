import AppKit
import WebKit

/// Application web view.
///
/// WebKit owns the page context menu, so replacing `NSView.menu` is not
/// enough. Overriding `willOpenMenu` lets the app inject its own item into
/// the menu WebKit actually displays.
final class BrowserWebView: WKWebView {
    static let generateQRCodeItemID = NSUserInterfaceItemIdentifier(
        rawValue: "com.onebuckapp.whatever.generateQRCode"
    )

    /// Called when the injected page-menu item is chosen, with the
    /// right-clicked link's address when the menu was opened on a link, or
    /// nil for the page itself. Set by the hosting pane.
    var onGenerateQRCode: ((URL?) -> Void)?

    /// Called when link hover changes, with the hovered link or nil when the
    /// pointer leaves links. Set by the hosting pane, which owns the bubble.
    var onLinkHover: ((URL?) -> Void)?

    /// The relay this page's configuration posts hover messages to. Held
    /// strongly: the content controller retains its handlers, and the relay
    /// holds this view weakly, so neither direction leaks. Replaced on every
    /// script-list rebuild, one per page.
    var hoverRelay: LinkHoverRelay?

    /// Called for the retargeted "Open Link" item, with the right-clicked
    /// link's address. A menu open is a deliberate new-tab gesture, not an
    /// in-page click, so this opens a new tab where WebKit would have loaded
    /// in place. Set by the hosting pane, which knows the tab's privacy mode
    /// and window.
    var onOpenLinkInNewTab: ((URL) -> Void)?

    /// Called for the retargeted "Open Link in New Window" item. WebKit drops
    /// this one (its new-view request is declined, so the navigation never
    /// starts); handling it here with the resolved address makes it work.
    var onOpenLinkInNewWindow: ((URL) -> Void)?

    /// WebKit's stable menu identifiers (locale-independent, unlike titles).
    ///
    /// The `WKMenuItemIdentifier*` constants are private API, so the raw
    /// values are written out: the constant name minus its leading
    /// underscore. Unchanged across macOS releases to date.
    private static let openLinkID = "WKMenuItemIdentifierOpenLink"
    private static let openLinkInNewWindowID = "WKMenuItemIdentifierOpenLinkInNewWindow"
    private static let downloadLinkedFileID = "WKMenuItemIdentifierDownloadLinkedFile"

    /// What the retargeted "Open Link" item is renamed to. WebKit's title
    /// describes its own behavior (load in place); ours opens a new tab, and
    /// the menu should say so next to "Open Link in New Window".
    static let openLinkInNewTabTitle = "Open Link in New Tab"

    /// The right-clicked link's address for the open menu, resolving while
    /// the menu opens and read when an item is chosen.
    ///
    /// Resolved at menu time, not click time: the press point is freshest
    /// then, and whatever the page does between the menu and the choice —
    /// lazy images landing, fonts swapping, an SPA navigating — cannot move
    /// the link out from under an already-answered question. Re-querying at
    /// click time missed on exactly those real-world pages, every time the
    /// layout shifted in between, which is why the items worked once and
    /// then not again. The task runs on the main actor: script evaluation is
    /// a UI API, and background evaluation answered nil whenever WebKit felt
    /// strict about it.
    private var linkMenuResolution: Task<URL?, Never>?
    /// WebKit's original target and action per retargeted item, so a click
    /// that cannot be resolved still does what WebKit would have done.
    /// Keyed by identifier: there is at most one of each per menu.
    private var linkFallbacks: [NSUserInterfaceItemIdentifier: (AnyObject?, Selector?)] = [:]

    /// Whether WebKit should be left to paint an opaque page background.
    ///
    /// Always off: an opaque view flashes white before the first paint, and
    /// the window behind the page is the correct thing to show there.
    /// `isOpaque` is get-only on `NSView`, so this is the only way to
    /// answer it, and this subclass is the only place that legally can.
    ///
    /// Necessary but nowhere near sufficient for seeing through a page:
    /// WebKit paints the *page's* own background whatever this says. See
    /// `PageTransparency`.
    var drawsOpaquePageBackground = true {
        didSet {
            guard drawsOpaquePageBackground != oldValue else { return }
            layer?.backgroundColor = drawsOpaquePageBackground ? nil : .clear
            needsDisplay = true
        }
    }

    override var isOpaque: Bool {
        drawsOpaquePageBackground
    }

    /// Whether the page is allowed to see the mouse.
    ///
    /// Set to `false` for as long as a modal card covers the window. Closing the
    /// card puts it straight back, so nothing about the page is left off.
    var takesMouseInput = true {
        didSet {
            guard takesMouseInput != oldValue else { return }
            if takesMouseInput {
                restoreMouseTrackingAreas()
            } else {
                suppressMouseTrackingAreas()
                // AppKit caches the cursor per view, so it has to be told to
                // recompute or it keeps drawing the link hand it last cached.
                NSCursor.arrow.set()
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    // MARK: - Mouse input gate

    /// Tracking areas taken off this view's subtree while gated, kept so they can be
    /// handed back exactly as they were.
    ///
    /// Both halves of this are load-bearing, and the first is why the gate is done
    /// this way at all. WebKit adds its hover and cursor tracking areas to the
    /// `WKWebView` itself but hands them to a private `WKMouseTrackingObserver`,
    /// which is not a responder. Messages for those areas therefore never reach
    /// this subclass: overriding `mouseMoved` or `cursorUpdate` here cannot stop a
    /// link hand or link hover, because the code handling them is not ours.
    /// Removing the areas is the only thing that reaches it.
    ///
    /// Keeping the objects back matters just as much. WebKit does not reliably
    /// rebuild them from `updateTrackingAreas`, and measured, a page that returned
    /// from dismissal with none had lost hover and the link cursor for good.
    /// Re-adding the very same objects needs no cooperation from WebKit and leaves
    /// the view exactly as it was.
    private var suppressedTrackingAreas: [(view: NSView, area: NSTrackingArea)] = []

    /// Takes every tracking area in the subtree off, remembering where each came
    /// from. A no-op while the view is interactive.
    func suppressMouseTrackingAreas() {
        guard !takesMouseInput else { return }
        var removed: [(view: NSView, area: NSTrackingArea)] = []
        for view in subtree(of: self) {
            for area in view.trackingAreas {
                view.removeTrackingArea(area)
                removed.append((view, area))
            }
        }
        suppressedTrackingAreas.append(contentsOf: removed)
    }

    /// Puts back everything `suppressMouseTrackingAreas` took.
    private func restoreMouseTrackingAreas() {
        for entry in suppressedTrackingAreas {
            entry.view.addTrackingArea(entry.area)
        }
        suppressedTrackingAreas.removeAll()
        // WebKit keeps its own record of what it installed, so letting it rebuild
        // here drops any area it added while the gate was closed and leaves the
        // current page with the areas it actually wants. Harmless if it decides to
        // keep the ones just handed back.
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    /// Re-applies the gate to areas WebKit added after it closed.
    ///
    /// A page that keeps loading behind an open card installs fresh tracking areas,
    /// and those would hand the pointer straight back to the page. Called when a
    /// load finishes.
    func reassertMouseInputSuppression() {
        suppressMouseTrackingAreas()
    }

    /// This view and everything under it, breadth first.
    private func subtree(of view: NSView) -> [NSView] {
        var found: [NSView] = [view]
        for subview in view.subviews {
            found.append(contentsOf: subtree(of: subview))
        }
        return found
    }

    /// Lets WebKit manage its own areas, then takes them away again while gated.
    ///
    /// `super` runs in both cases deliberately. WebKit's bookkeeping has to happen
    /// or it may never rebuild anything later; only the areas themselves are
    /// withheld, which is also what makes this the right place to catch the ones
    /// it adds mid-card.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        suppressMouseTrackingAreas()
    }

    /// Catch-all for the areas WebKit installs without asking.
    ///
    /// `updateTrackingAreas` covers the paths that go through AppKit's tracking
    /// machinery, but not all of them: a page that loads or scrolls behind an open
    /// card can end up with an area that arrived by neither route, which measured as
    /// one leaking back in. Laying out is the remaining moment that reliably
    /// follows any change to the page, and suppression is a no-op whenever the view
    /// is interactive, so this costs one walk of a two-view tree.
    override func layout() {
        super.layout()
        suppressMouseTrackingAreas()
    }

    // MARK: - Responder gating

    // These are not what stops the cursor — `WKMouseTrackingObserver` handles that
    // and never routes through here — but they are what stops a genuine hit on the
    // page: no presses, and no `mouseMoved` to drive page-side hover.

    override func hitTest(_ point: NSPoint) -> NSView? {
        takesMouseInput ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard takesMouseInput else { return }
        // Control-click opens a context menu too, without a right-button
        // press to record below.
        if event.modifierFlags.contains(.control) {
            noteMenuPress(event)
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard takesMouseInput else { return }
        super.mouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard takesMouseInput else { return }
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        guard takesMouseInput else { return }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard takesMouseInput else { return }
        super.mouseExited(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard takesMouseInput else {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard takesMouseInput else { return }
        super.scrollWheel(with: event)
    }

    /// Records a press that may open a context menu, in view coordinates.
    ///
    /// Called while the event is still the genuine press. By the time
    /// `willOpenMenu` runs, WebKit has replaced it with a menu-tracking
    /// pseudo-event from another window, whose location is meaningless —
    /// resolving the link from that point always missed.
    private func noteMenuPress(_ event: NSEvent) {
        menuPressPoint = (convert(event.locationInWindow, from: nil), Date())
    }

    override func rightMouseDown(with event: NSEvent) {
        guard takesMouseInput else { return }
        noteMenuPress(event)
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard takesMouseInput else { return }
        noteMenuPress(event)
        super.rightMouseUp(with: event)
    }

    /// A recent genuine press and when it happened, for the menu to resolve
    /// its link from. Nil until the first right-button press.
    private var menuPressPoint: (point: NSPoint, at: Date)?

    // MARK: - Page context menu

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // WebKit can reuse a menu object, so do not stack duplicate items.
        if !menu.items.contains(where: { $0.identifier == Self.generateQRCodeItemID }) {
            let item = NSMenuItem(
                title: "Generate QR Code",
                action: #selector(handleGenerateQRCode(_:)),
                keyEquivalent: ""
            )
            item.identifier = Self.generateQRCodeItemID
            item.target = self
            item.isEnabled = true
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        retargetLinkItems(in: menu)
    }

    @objc private func handleGenerateQRCode(_ sender: NSMenuItem?) {
        // Awaits the menu-time resolution like the open-link items: on a
        // link menu this is the right-clicked link, otherwise nil for the
        // page itself.
        let resolution = linkMenuResolution
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onGenerateQRCode?(await resolution?.value)
        }
    }

    /// Picks the point the menu resolves its link from.
    ///
    /// Pure so tests pin the priority without a web view: a fresh press
    /// beats the cursor, a stale press is ignored (a right-click that opened
    /// no menu must not leak into a later keyboard-opened one), and with
    /// neither there is no point.
    static func menuResolutionPoint(
        press: NSPoint?,
        pressedAt: Date?,
        cursor: NSPoint?,
        now: Date = Date()
    ) -> NSPoint? {
        if let press, let pressedAt, now.timeIntervalSince(pressedAt) < 2 {
            return press
        }
        return cursor
    }

    /// Where the cursor is now, in view coordinates, if it is over this
    /// view at all. Fallback for menus no press opened (keyboard and edge
    /// cases): the cursor is where the user was looking, which still beats
    /// the menu event.
    private func cursorPoint() -> NSPoint? {
        guard let window else { return nil }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return bounds.contains(point) ? point : nil
    }

    /// Takes WebKit's link items over and drops its download item.
    ///
    /// "Download Linked File" bypasses the download pipeline (menu downloads
    /// never consult the navigation policy), so it would save files the app
    /// never records. The open items keep their titles and positions; only
    /// their behavior changes, to the handlers below.
    private func retargetLinkItems(in menu: NSMenu) {
        menu.items
            .filter { $0.identifier?.rawValue == Self.downloadLinkedFileID }
            .forEach(menu.removeItem)
        // Resolved now rather than when the user chooses, so the page state
        // the user saw is the one queried. The link itself comes from the
        // page's own `contextmenu` event (see `PageLinkCapture`); the press
        // point is only a fallback for pages that never fired one.
        linkMenuResolution?.cancel()
        let point = Self.menuResolutionPoint(
            press: menuPressPoint?.point,
            pressedAt: menuPressPoint?.at,
            cursor: cursorPoint()
        )
        linkMenuResolution = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return nil }
            let script = Self.linkResolutionScript(
                viewX: point?.x,
                viewY: point.map { bounds.height - $0.y }
            )
            let raw = try? await self.evaluateJavaScript(script)
            guard let href = raw as? String, !href.isEmpty, let url = URL(string: href) else {
                return nil
            }
            return url
        }
        for item in menu.items {
            switch item.identifier?.rawValue {
            case Self.openLinkID:
                item.title = Self.openLinkInNewTabTitle
                takeOver(item, action: #selector(handleOpenLink(_:)))
            case Self.openLinkInNewWindowID:
                takeOver(item, action: #selector(handleOpenLinkInNewWindow(_:)))
            default:
                break
            }
        }
    }

    /// Hands `item` to this view, remembering WebKit's original target so a
    /// click that cannot be resolved still does what WebKit would have done.
    private func takeOver(_ item: NSMenuItem, action: Selector) {
        guard item.target !== self, let id = item.identifier else { return }
        linkFallbacks[id] = (item.target, item.action)
        item.target = self
        item.action = action
    }

    @objc private func handleOpenLink(_ sender: NSMenuItem) {
        // Awaits the menu-time resolution: usually already answered, in
        // which case this continues without suspending.
        let resolution = linkMenuResolution
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let url = await resolution?.value {
                self.onOpenLinkInNewTab?(url)
            } else {
                self.fallBack(sender)
            }
        }
    }

    @objc private func handleOpenLinkInNewWindow(_ sender: NSMenuItem) {
        let resolution = linkMenuResolution
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let url = await resolution?.value {
                self.onOpenLinkInNewWindow?(url)
            } else {
                self.fallBack(sender)
            }
        }
    }

    /// Replays WebKit's original item behavior: the target is WebKit's own
    /// menu proxy, held rather than named, so no private API is touched.
    private func fallBack(_ sender: NSMenuItem) {
        guard let id = sender.identifier,
            let (target, action) = linkFallbacks[id],
            let action,
            let target
        else {
            return
        }
        _ = NSApp.sendAction(action, to: target, from: sender)
    }

    /// The script the menu runs to find the right-clicked link.
    ///
    /// Prefers the href the page's own `contextmenu` event captured, which
    /// needs no coordinate math and cannot drift with layout, scroll, or
    /// zoom. Falls back to the point-based anchor lookup only when the page
    /// never fired a `contextmenu` (or the script was not yet installed), and
    /// clears the captured value either way so it cannot leak into the next
    /// menu.
    static func linkResolutionScript(viewX: CGFloat?, viewY: CGFloat?) -> String {
        let coordinate: String
        if let viewX, let viewY {
            coordinate = "return \(linkLookupScript(viewX: viewX, viewY: viewY));"
        } else {
            coordinate = "return null;"
        }
        return """
        (() => {
            const captured = window.\(PageLinkCapture.variable);
            window.\(PageLinkCapture.variable) = null;
            if (captured) return captured;
            \(coordinate)
        })()
        """
    }

    /// The anchor lookup for a right-click at view coordinates with a
    /// top-left origin. Pure so tests can prove the coordinate math without
    /// a web view. The menu's fallback path, not its first choice.
    static func linkLookupScript(viewX: CGFloat, viewY: CGFloat) -> String {
        """
        (() => {
            const zoom = (window.visualViewport && window.visualViewport.scale) || 1;
            const x = \(viewX) / zoom - window.scrollX;
            const y = \(viewY) / zoom - window.scrollY;
            const el = document.elementFromPoint(x, y);
            const a = el && el.closest ? el.closest('a[href]') : null;
            return a ? a.href : null;
        })()
        """
    }
}