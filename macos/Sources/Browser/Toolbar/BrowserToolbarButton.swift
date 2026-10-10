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
    /// tighter than either: near the 22pt a regular `NSControlSize` bezel
    /// button would have wanted, plus breathing room around the glyph.
    private static let side: CGFloat = 26
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

    /// Ink height every toolbar glyph paints at, bundled or system.
    /// Measured, not guessed: the 13.5pt medium system cuts render
    /// 12–15pt of ink, clustering at 14–15, while the bundled vectors
    /// boxed small painted ~11pt — visibly smaller, with looser padding
    /// than their neighbors. Vectors are boxed per asset below to land in
    /// the same band instead.
    static let glyphInkHeight: CGFloat = 14.5

    /// Loads a bundled vector as a toolbar glyph, boxed so its ink height
    /// lands on `glyphInkHeight`.
    ///
    /// `inkRatio` is the asset's ink height over its box height, measured
    /// per asset from an 18pt render (RSS 0.75, shields ~0.83–0.88,
    /// fingerprint 0.75). The box rounds to whole points: a fractional box
    /// paints the vector soft, the same disease the tab strip's edge
    /// snapping cures.
    ///
    /// The image is copied before sizing: `NSImage(named:)` returns a
    /// shared instance, so sizing it in place would move every other use
    /// of the asset to the last size set.
    static func bundledGlyphImage(named name: String, inkRatio: CGFloat) -> NSImage? {
        guard inkRatio > 0,
              let image = NSImage(named: name)?.copy() as? NSImage
        else {
            return nil
        }
        image.isTemplate = true
        let box = (glyphInkHeight / inkRatio).rounded()
        image.size = NSSize(width: box, height: box)
        return image
    }

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

    /// Fixed fitting size: the strip's stack views size the alignment axis
    /// from `fittingSize`, not from constraints, and the cell behind this
    /// button derives its fitting height from the glyph — so system glyphs
    /// came out 26–29pt tall while the smaller bundled vectors held 22,
    /// and every button hovered a different fill. The explicit constraints
    /// above pin the distribution axis; this pins the other one. Static so
    /// the size is testable without laying out a strip.
    static let fittingDimensions = NSSize(width: outerWidth, height: outerHeight)

    override var fittingSize: NSSize {
        Self.fittingDimensions
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