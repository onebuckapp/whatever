import AppKit

/// A toolbar button with no bezel and a barely-there fill on hover.
///
/// The strip's buttons were `.texturedRounded`, which draws a visible bezel around
/// every glyph whether or not it is in use — six permanent outlines sitting above
/// the page. This draws only the glyph, and paints a rounded fill underneath it
/// only while the pointer is over it, which is what the rest of the app's controls
/// already look like.
///
/// The hover tracking is `.activeInKeyWindow`, so a window that is not frontmost
/// shows no highlight at all, matching what AppKit does for its own buttons.
@MainActor
final class BrowserToolbarButton: NSButton {
    /// The strip is 52pt and the address field beside these is 32pt, so these sit
    /// tighter than either: close to the 22pt a regular `NSControlSize` bezel
    /// button would have wanted.
    private static let side: CGFloat = 24
    private static let fillRadius: CGFloat = 8
    /// Outer width including the padding the fixed constraints add, for
    /// containers that lay this out by hand and need to reserve its space.
    static let outerWidth: CGFloat = side + 6
    static let outerHeight: CGFloat = side - 2

    /// Faint enough to be a hint rather than a highlight. Neutral rather than
    /// accent-tinted, so it does not imply the button is the default action.
    private static let hoverAlpha: CGFloat = 0.06
    private static let pressedAlpha: CGFloat = 0.12

    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false

    /// Unseen finished downloads for the badge. Zero hides it. Set by the
    /// toolbar controller from the shared badge center.
    var badgeCount = 0 {
        didSet {
            guard badgeCount != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isBordered = false
        // `.momentaryChange` without `.pushOnPushOff`, and no bezel: a momentary
        // highlight of our own is drawn below instead.
        setButtonType(.momentaryChange)
        focusRingType = .none
        imagePosition = .imageOnly
        imageHugsTitle = false
        translatesAutoresizingMaskIntoConstraints = false
        // Explicit rather than intrinsic alone: the intrinsic size did not hold the
        // height — buttons came out at their glyph's height plus bezel margins and
        // overflowed the cluster.
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side + 6),
            heightAnchor.constraint(equalToConstant: Self.side - 2),
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    override var acceptsFirstResponder: Bool {
        // Never: a button that takes focus would pull the caret out of the address
        // field, and tabbing through six chrome buttons nobody keyboard-navigates to
        // is not worth the ring.
        false
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    /// Cleared when the button is disabled so it cannot keep a highlight it is no
    /// longer allowed to act on.
    override var isEnabled: Bool {
        didSet {
            if isEnabled != oldValue {
                isHovering = false
                needsDisplay = true
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let alpha = isHighlighted ? Self.pressedAlpha : (isHovering ? Self.hoverAlpha : 0)
        if isEnabled, alpha > 0 {
            let path = NSBezierPath(
                roundedRect: bounds,
                xRadius: Self.fillRadius,
                yRadius: Self.fillRadius
            )
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            path.fill()
        }
        // With `isBordered` false this draws the glyph alone.
        super.draw(dirtyRect)
        drawBadge()
    }

    /// Unseen-downloads counter: a red disc tucked into the top-trailing
    /// corner, capped at 9+. Drawn in `draw(_:)` rather than as a subview so
    /// it tracks the glyph through resizes with no layout of its own.
    private func drawBadge() {
        guard badgeCount > 0 else { return }
        let text = badgeCount > 9 ? "9+" : "\(badgeCount)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textWidth = ceil((text as NSString).size(withAttributes: attributes).width)
        let width = max(16, textWidth + 8)
        let disc = NSRect(
            x: bounds.maxX - width + 2,
            y: bounds.maxY - 15,
            width: width,
            height: 15
        )
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: disc, xRadius: 7.5, yRadius: 7.5).fill()
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(
                x: disc.midX - textSize.width / 2,
                y: disc.midY - textSize.height / 2 + 0.5
            ),
            withAttributes: attributes
        )
    }
}