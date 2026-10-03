import AppKit

/// Transparent modal layer that blocks mouse interaction with everything
/// below it while a card is presented.
///
/// The grain overlay is the opposite case: it must never intercept input.
/// This one exists precisely to swallow it, so clicks, drags, scrolls,
/// and hover tracking over the page (including its `WKWebView`) cannot
/// reach the content behind a modal card.
///
/// It draws nothing, never becomes first responder, and stays out of
/// accessibility, so the only visible difference while it is installed
/// is that the underlying UI stops responding to the mouse.
@MainActor
final class ModalEventShieldView: NSView {
    /// Called for any pointer press that lands on the shield. Hosts use
    /// it to dismiss whatever they presented.
    var onClick: (() -> Void)?

    override var isOpaque: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    /// Consumes the event instead of passing it through. Returning `nil`
    /// here — as the grain overlay does — would let AppKit keep walking
    /// down to the page, which is exactly what must not happen while a
    /// modal card is up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    override func otherMouseDown(with event: NSEvent) {
        onClick?()
    }

    /// A press that starts on the page and is released over the shield
    /// (or vice versa) must not activate the content underneath either.
    override func mouseUp(with event: NSEvent) {
        onClick?()
    }

    /// Scroll, magnify, and rotate land here and go nowhere, so the page
    /// cannot be scrolled or zoomed while the card is presented.
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}

    /// Covers `container` and stays below `interactive` (the popup host),
    /// so the card itself remains fully usable while the rest of the
    /// window goes inert.
    @discardableResult
    static func install(
        in container: NSView,
        below interactive: NSView? = nil,
        onClick: @escaping () -> Void
    ) -> ModalEventShieldView {
        let shield = ModalEventShieldView()
        shield.onClick = onClick
        shield.translatesAutoresizingMaskIntoConstraints = false
        if let interactive {
            container.addSubview(shield, positioned: .below, relativeTo: interactive)
        } else {
            container.addSubview(shield, positioned: .above, relativeTo: nil)
        }
        NSLayoutConstraint.activate([
            shield.topAnchor.constraint(equalTo: container.topAnchor),
            shield.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shield.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            shield.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        shield.setAccessibilityElement(false)
        return shield
    }
}