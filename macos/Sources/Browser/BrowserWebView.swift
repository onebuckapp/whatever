import AppKit
import WebKit

/// Application web view.
///
/// WebKit owns the page context menu, so replacing `NSView.menu` is not
/// enough. Overriding `willOpenMenu` lets the app inject its own item into
/// the menu WebKit actually displays.
final class BrowserWebView: WKWebView {
    static let generateQRCodeItemID = NSUserInterfaceItemIdentifier(
        rawValue: "com.onebuckapps.whatever.generateQRCode"
    )

    /// Called when the injected page-menu item is chosen.
    var onGenerateQRCode: (() -> Void)?

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

    /// The right-click point in view coordinates, recorded when the menu
    /// opens and read when an item is chosen.
    private var linkMenuPoint: NSPoint?
    /// WebKit's original target and action per retargeted item, so a click
    /// that cannot be resolved still does what WebKit would have done.
    /// Keyed by identifier: there is at most one of each per menu.
    private var linkFallbacks: [NSUserInterfaceItemIdentifier: (AnyObject?, Selector?)] = [:]

    /// Whether WebKit should be left to paint an opaque page background.
    ///
    /// Turned off for the opt-in "show the window background through pages"
    /// setting. `isOpaque` is get-only on `NSView`, so this is the only way to
    /// answer it, and this subclass is the only place that legally can.
    ///
    /// Necessary but nowhere near sufficient: WebKit paints the *page's* own
    /// background whatever this says, so on its own this changes nothing visible.
    /// See `PageTransparency`.
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

        retargetLinkItems(in: menu, event: event)
    }

    @objc private func handleGenerateQRCode(_ sender: NSMenuItem?) {
        onGenerateQRCode?()
    }

    /// Takes WebKit's link items over and drops its download item.
    ///
    /// "Download Linked File" bypasses the download pipeline (menu downloads
    /// never consult the navigation policy), so it would save files the app
    /// never records. The open items keep their titles and positions; only
    /// their behavior changes, to the handlers below.
    private func retargetLinkItems(in menu: NSMenu, event: NSEvent) {
        menu.items
            .filter { $0.identifier?.rawValue == Self.downloadLinkedFileID }
            .forEach(menu.removeItem)
        // Recorded for click-time resolution rather than resolved now: the
        // address is re-queried when the user chooses, so there is no race
        // and no stale cache.
        linkMenuPoint = convert(event.locationInWindow, from: nil)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case Self.openLinkID:
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
        resolveLinkURL { [weak self] url in
            guard let self else { return }
            if let url {
                self.onOpenLinkInNewTab?(url)
            } else {
                self.fallBack(sender)
            }
        }
    }

    @objc private func handleOpenLinkInNewWindow(_ sender: NSMenuItem) {
        resolveLinkURL { [weak self] url in
            guard let self else { return }
            if let url {
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

    /// Finds the right-clicked link's address.
    ///
    /// `elementFromPoint` wants viewport coordinates in CSS pixels, origin
    /// top-left: AppKit's bottom-left origin is flipped and the scroll offset
    /// and page zoom are subtracted in the same script, so layout between the
    /// menu and the click cannot skew it. Links inside frames resolve through
    /// the top document only. Nil when the point is not over a link, or when
    /// scripting is off — the caller then falls back to WebKit's behavior.
    private func resolveLinkURL(_ finish: @escaping (URL?) -> Void) {
        guard let point = linkMenuPoint else {
            finish(nil)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let script = Self.linkLookupScript(viewX: point.x, viewY: bounds.height - point.y)
            let raw = try? await self.evaluateJavaScript(script)
            guard let href = raw as? String, let url = URL(string: href) else {
                finish(nil)
                return
            }
            finish(url)
        }
    }

    /// The anchor lookup for a right-click at view coordinates with a
    /// top-left origin. Pure so tests can prove the coordinate math without
    /// a web view.
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