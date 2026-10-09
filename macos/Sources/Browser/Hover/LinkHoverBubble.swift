import AppKit

/// The floating status bubble showing the hovered link's full address.
///
/// A bottom-left pill over the page, Chrome-style: it overlays instead of
/// pushing the page up, never takes clicks (`hitTest` refuses everything),
/// and fades in and out. One per pane, fed by the view's `onLinkHover`.
final class LinkHoverBubble: NSView {
    private let label = NSTextField(labelWithString: "")

    /// Whether the bubble is currently presented. Tests pin the transitions
    /// through this rather than the fade animation.
    private(set) var isShowing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        layer?.cornerRadius = 7

        label.font = .systemFont(ofSize: 11)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Floating furniture, not a control: presses fall through to the page.
        nil
    }

    func show(_ url: URL, onPage pageURL: URL?) {
        label.stringValue = Self.displayText(link: url, onPage: pageURL)
        // Already up: just the text changes, so a stream of hovers never
        // restarts the fade.
        guard !isShowing else { return }
        isShowing = true
        isHidden = false
        animator().alphaValue = 1
    }

    /// The bubble text: the full address, with a ↗ suffix for links leaving
    /// the current site.
    static func displayText(link: URL, onPage pageURL: URL?) -> String {
        isExternal(link: link, onPage: pageURL)
            ? "\(link.absoluteString) ↗" : link.absoluteString
    }

    /// Whether `link` leaves the site `pageURL` is on. Hosts compare
    /// case-insensitively with a leading `www.` ignored, so
    /// `www.example.com` links on `example.com` stay unmarked. A link with
    /// no host (mailto:, tel:) counts as leaving.
    static func isExternal(link: URL, onPage pageURL: URL?) -> Bool {
        guard let pageHost = pageURL?.host else { return true }
        guard let linkHost = link.host else { return true }
        return stripped(linkHost) != stripped(pageHost)
    }

    private static func stripped(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    /// The address currently displayed, for tests.
    var displayedAddress: String { label.stringValue }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        animator().alphaValue = 0
        // The fade-out leaves a transparent view behind; unhide on the next
        // show. Delayed to outlive the animation rather than snapping it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isShowing else { return }
            self.isHidden = true
        }
    }
}
