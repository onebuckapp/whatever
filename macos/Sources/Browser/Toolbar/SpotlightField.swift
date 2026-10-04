import AppKit

/// The address field: a drawn "spotlight" with a transparent real text field on top.
///
/// Two layers rather than one `NSSearchField`, because the stock control cannot do
/// what this needs:
///
/// * Its internal layout is drawn from metrics fixed when the control was created.
///   Change the font or the height and the magnifier, the text and the clear button
///   stop agreeing on a centre line — which is exactly the "text slides over the
///   icon" symptom. Here the chrome is drawn by `draw(_:)` and the text field is
///   positioned against the same padding, so they cannot drift apart.
/// * The dropdown has to be pixel-continuous with the field: same left and right
///   edges, same 1pt border, bottom corners squared while it is open so the two
///   read as one shape split by a hairline. A stock field's rounded bezel cannot
///   participate in that.
///
/// The text field is borderless and has its background turned off, so it is only
/// ever a caret and some glyphs on top of what `draw(_:)` painted.
@MainActor
final class SpotlightField: NSView {
    // MARK: Geometry

    /// Matches the corner radius the dropdown uses, so the two are the same curve.
    static let cornerRadius: CGFloat = 10
    /// The 1pt border, drawn at the same radius as the fill so it tracks it.
    private static let borderWidth: CGFloat = 1
    /// Room for the magnifier plus the gap to the text, measured from the left edge.
    private static let leadingInset: CGFloat = 30
    /// Same on the right, for the clear button.
    private static let trailingInset: CGFloat = 24
    private static let glyphSide: CGFloat = 14

    // MARK: State

    /// The real input. Transparent and borderless: everything visible around it is
    /// painted by this view.
    let textField = NSTextField()
    private let magnifier = NSImageView()
    private let clearButton = NSButton()

    /// Whether the dropdown is showing. Squared-off bottom corners and the hairline
    /// separator follow from this.
    var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            needsDisplay = true
            updateClearButton()
        }
    }

    /// Replaces `controlTextDidChange`, which a borderless field still sends but
    /// which this view does not use.
    var onTextChanged: ((String) -> Void)?
    /// A click on the chrome, or the field gaining focus by any means, so the
    /// dropdown can open on a click and not only on a keystroke.
    ///
    /// Both are needed: a click on the text itself never reaches this view's
    /// `mouseDown`, the text field swallows it, so chrome clicks alone would leave
    /// the most-clicked part of the bar dead.
    var onActivated: (() -> Void)?
    /// Reported so `syncControls` can leave the field alone while it is being typed
    /// into. A drawn field has no `isEditing` of its own to ask, unlike the
    /// `NSTextField` this replaced.
    var onEditingChanged: ((Bool) -> Void)?
    /// Set by `SpotlightController`. The arrow keys move the dropdown's selection
    /// only while one is open, and the caret otherwise.
    var onMoveSelection: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    var onSubmit: ((String) -> Void)?

    /// Whether the input currently holds focus. Distinct from `isOpen`, which is
    /// about the dropdown.
    private(set) var isEditing = false

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTextField()
        configureMagnifier()
        configureClearButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureTextField() {
        let field = textField
        field.translatesAutoresizingMaskIntoConstraints = false
        // Borderless and unpainted. Both of these are what make the field invisible:
        // the stock bezel would draw a second rounded rect on top of this one, and
        // a background would cover the spotlight fill.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        // Set explicitly rather than left to the default. Replacing or configuring a
        // field's pieces has already reset this once, and a non-editable field
        // refuses to install a field editor while still reporting a successful
        // `makeFirstResponder`, so it looks focused and drops every keystroke.
        field.isSelectable = true
        field.cell?.usesSingleLineMode = true
        // Belt and braces with the line above: single-line mode alone still left
        // `wraps` true, so the shared field editor wrapped a long URL into two
        // lines and grew to 34pt inside a 20pt field, spilling under the pill.
        // With wrapping off it scrolls horizontally and the arrows walk the caret
        // through the address.
        field.cell?.wraps = false
        field.cell?.truncatesLastVisibleLine = true
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = "Search or enter address"
        field.delegate = self
        addSubview(field)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.leadingInset
            ),
            field.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.trailingInset
            ),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Enough for the font's line height plus the focus ring the field would
            // draw if it had one, which it does not.
            field.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private func configureMagnifier() {
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        magnifier.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )
        // Secondary so it recedes behind the text, which is what it is for.
        magnifier.contentTintColor = .secondaryLabelColor
        addSubview(magnifier)
        NSLayoutConstraint.activate([
            magnifier.centerXAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.leadingInset - Self.glyphSide
            ),
            magnifier.centerYAnchor.constraint(equalTo: centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: Self.glyphSide),
            magnifier.heightAnchor.constraint(equalToConstant: Self.glyphSide),
        ])
    }

    private func configureClearButton() {
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Clear address"
        )
        clearButton.isBordered = false
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.focusRingType = .none
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.isHidden = true
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            clearButton.centerXAnchor.constraint(
                equalTo: trailingAnchor,
                // 4pt further inside than centred in the padding, so it clears the
                // bar's rounded trailing corner rather than riding its edge.
                constant: -(Self.trailingInset - Self.glyphSide) - 4
            ),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @objc private func clear() {
        textField.stringValue = ""
        updateClearButton()
        onTextChanged?("")
        window?.makeFirstResponder(textField)
    }

    // MARK: Focus

    @discardableResult
    func focusInput() -> Bool {
        guard let window else { return false }
        if window.makeFirstResponder(textField) { return true }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            _ = window.makeFirstResponder(self.textField)
        }
        return false
    }

    // MARK: Clicking

    /// A click on the chrome — anywhere that is not the text field or the clear
    /// button — focuses the input and reports the click so the dropdown can open.
    ///
    /// Without this the spotlight would only be clickable in the dead space around
    /// the glyphs, because a borderless text field's hit area is its own text.
    override func mouseDown(with event: NSEvent) {
        onActivated?()
        focusInput()
    }

    // MARK: Drawing

    /// A rounded rectangle whose top and bottom corners can differ.
    ///
    /// `NSBezierPath(roundedRect:xRadius:yRadius:)` rounds all four at once, so it
    /// cannot express a field whose bottom two corners square off to meet the
    /// dropdown. Both shapes are drawn through this one function, which is what
    /// makes the field's curve and the panel's the same curve: drawn separately,
    /// the two disagreed by a visible fraction of a point at the join.
    ///
    /// Assumes the view is not flipped, which is true of both callers: in this
    /// coordinate system `maxY` is the top edge.
    static func outline(in rect: NSRect, topRadius: CGFloat, bottomRadius: CGFloat) -> NSBezierPath {
        // A radius wider than half the shorter side would make the arcs overlap and
        // the path self-intersect, so both are capped.
        let cap = min(rect.width, rect.height) / 2
        let top = min(max(topRadius, 0), cap)
        let bottom = min(max(bottomRadius, 0), cap)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

        let path = NSBezierPath()
        path.move(to: NSPoint(x: minX + top, y: maxY))
        path.line(to: NSPoint(x: maxX - top, y: maxY))
        // Each arc runs clockwise, from the edge the pen is already on to the edge
        // it is turning onto. The angles are in the y-up system, measured
        // anticlockwise from the positive x-axis, so the quarter at the top-right
        // corner runs 90 to 0: it starts at the top edge and ends at the right
        // edge. Getting the direction wrong does not fail loudly — AppKit draws a
        // straight chord from the pen to the arc's start and sweeps the corner
        // backwards, which is how the field grew "wings" at its left and right
        // edges.
        appendArc(to: path, center: NSPoint(x: maxX - top, y: maxY - top), radius: top, from: 90, to: 0, clockwise: true)
        path.line(to: NSPoint(x: maxX, y: minY + bottom))
        appendArc(to: path, center: NSPoint(x: maxX - bottom, y: minY + bottom), radius: bottom, from: 0, to: 270, clockwise: true)
        path.line(to: NSPoint(x: minX + bottom, y: minY))
        appendArc(to: path, center: NSPoint(x: minX + bottom, y: minY + bottom), radius: bottom, from: 270, to: 180, clockwise: true)
        path.line(to: NSPoint(x: minX, y: maxY - top))
        appendArc(to: path, center: NSPoint(x: minX + top, y: maxY - top), radius: top, from: 180, to: 90, clockwise: true)
        path.close()
        return path
    }

    /// The same outline minus its top edge, as an open path for stroking.
    ///
    /// The dropdown's top edge is not its own border: the bar's bottom border is
    /// the line between the two, so stroking a second one here would double it.
    /// This starts at the top-left corner, runs down the left side, around the
    /// bottom and up the right side, and its two ends butt-join the bar's border
    /// from below.
    static func sidesPath(in rect: NSRect, bottomRadius: CGFloat) -> NSBezierPath {
        let cap = min(rect.width, rect.height) / 2
        let bottom = min(max(bottomRadius, 0), cap)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

        let path = NSBezierPath()
        path.move(to: NSPoint(x: minX, y: maxY))
        path.line(to: NSPoint(x: minX, y: minY + bottom))
        // Counterclockwise here because this path walks the shape the other way
        // round from `outline`: down the left side first instead of across the
        // top.
        appendArc(to: path, center: NSPoint(x: minX + bottom, y: minY + bottom), radius: bottom, from: 180, to: 270, clockwise: false)
        path.line(to: NSPoint(x: maxX - bottom, y: minY))
        appendArc(to: path, center: NSPoint(x: maxX - bottom, y: minY + bottom), radius: bottom, from: 270, to: 360, clockwise: false)
        path.line(to: NSPoint(x: maxX, y: maxY))
        return path
    }

    /// The mirror image: rounded top corners, square bottom, no bottom edge.
    ///
    /// Draws tab cells, whose square bottoms meet the page. Same construction as
    /// `sidesPath` so every chrome outline in the window is the same curve code —
    /// a border built separately in layer coordinates visibly disagreed with the
    /// fill it was meant to follow.
    static func topSidesPath(in rect: NSRect, topRadius: CGFloat) -> NSBezierPath {
        let cap = min(rect.width, rect.height) / 2
        let top = min(max(topRadius, 0), cap)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

        let path = NSBezierPath()
        path.move(to: NSPoint(x: minX, y: minY))
        path.line(to: NSPoint(x: minX, y: maxY - top))
        appendArc(to: path, center: NSPoint(x: minX + top, y: maxY - top), radius: top, from: 180, to: 90, clockwise: true)
        path.line(to: NSPoint(x: maxX - top, y: maxY))
        appendArc(to: path, center: NSPoint(x: maxX - top, y: maxY - top), radius: top, from: 90, to: 0, clockwise: true)
        path.line(to: NSPoint(x: maxX, y: minY))
        return path
    }

    /// A quarter arc, or the straight corner it would have been when the radius is
    /// zero.
    ///
    /// Without the else branch a squared corner would move the pen to the arc's
    /// centre rather than round, leaving a notch in the edge.
    private static func appendArc(to path: NSBezierPath, center: NSPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat, clockwise: Bool) {
        guard radius > 0 else {
            path.line(to: NSPoint(x: center.x, y: center.y))
            return
        }
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
    }

    /// The spotlight's own shape: the field's fill and border, plus the rounded top
    /// corners of the dropdown hanging off its bottom edge.
    override func draw(_ dirtyRect: NSRect) {
        // Inset by half the stroke so the border is painted over the fill rather
        // than under it, which is what keeps the line exactly 1pt.
        let line = Self.borderWidth
        let rect = NSRect(
            x: line / 2,
            y: line / 2,
            width: max(0, bounds.width - line),
            height: max(0, bounds.height - line)
        )
        // Bottom corners square while the dropdown is showing, so the two shapes
        // share one straight edge and a single outline runs around both.
        let radius = Self.cornerRadius - line / 2
        let path = Self.outline(
            in: rect,
            topRadius: radius,
            bottomRadius: isOpen ? 0 : radius
        )
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = line
        path.stroke()
    }
}

// MARK: - Field editing

extension SpotlightField: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditing = true
        selectAllOnFocus()
        updateClearButton()
        onEditingChanged?(true)
        // Focusing the bar is an intentional visit to it, the same as clicking it:
        // an empty field offers the most recent history. Fired for text clicks too,
        // which `mouseDown` never sees.
        onActivated?()
    }

    /// Selects the field's text on focus, without fighting the click that focused it.
    ///
    /// A click places its caret on mouse-up, which runs after the focus delegate
    /// fires, so selecting there would first paint a selection and then watch it
    /// be undone. Worse, a deferred selection can land between the first
    /// keystrokes and leave the replacement itself selected, so continuing to
    /// type eats it. Keyboard focus selects immediately, since no click is
    /// coming. Mouse focus selects after the matching mouse-up, and only for a
    /// clean click: a drag keeps the drag's own selection.
    private func selectAllOnFocus() {
        guard let down = NSApp.currentEvent, down.type == .leftMouseDown else {
            textField.currentEditor()?.selectAll(nil)
            return
        }
        let anchor = down.locationInWindow
        // One-shot: removes itself on the matching mouse-up either way.
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if let monitor { NSEvent.removeMonitor(monitor) }
            guard let self,
                  event.window === self.textField.window,
                  abs(event.locationInWindow.x - anchor.x) < 4,
                  abs(event.locationInWindow.y - anchor.y) < 4
            else { return event }
            // After delivery, not before: selecting now would be undone by the
            // click's own caret placement. Queued work runs before the next event,
            // so no keystroke can slip in between and get swallowed by the selection.
            DispatchQueue.main.async { [weak self] in
                self?.textField.currentEditor()?.selectAll(nil)
            }
            return event
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        updateClearButton()
        onTextChanged?(textField.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        updateClearButton()
        onEditingChanged?(false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Arrows drive the dropdown's selection while it is open, and move the
        // caret otherwise. Returning true suppresses the caret move.
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard isOpen, let onMoveSelection else { return false }
            onMoveSelection(1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard isOpen, let onMoveSelection else { return false }
            onMoveSelection(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape, consumed only when there is a dropdown to close.
            guard isOpen, let onDismiss else { return false }
            onDismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSubmit?(textField.stringValue)
            return true
        }
        return false
    }

    /// Visible whenever there is text to clear, focused or not: clicking the bar
    /// with a URL in it must offer the × without typing first. Internal rather
    /// than private because `syncControls` sets the text directly on tab switches
    /// and has to refresh this with it.
    func updateClearButton() {
        clearButton.isHidden = textField.stringValue.isEmpty
    }
}