import AppKit

/// The find-in-page bar: query field, match count, steppers, and the three
/// matching options. A plain AppKit strip, not SwiftUI: it lives inside the
/// pane view below the page container, so it parks off-screen with the pane
/// and needs no hosting view.
///
/// Chrome only, no matching logic: every keystroke and toggle reports upward
/// to `FindController`, which runs the pipeline and tells this view what
/// count to show.
@MainActor
final class FindBarView: NSView {
    /// Fired on every keystroke, debounced by the controller.
    var onQueryChanged: ((String) -> Void)?
    /// Enter in the field, or the down stepper.
    var onNext: (() -> Void)?
    /// Shift+Enter in the field, or the up stepper.
    var onPrevious: (() -> Void)?
    /// Any checkbox toggled; the controller re-reads the three states.
    var onOptionsChanged: (() -> Void)?
    /// Escape in the field, or the × button.
    var onClose: (() -> Void)?

    let queryField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevButton = BrowserToolbarButton()
    private let nextButton = BrowserToolbarButton()
    private let closeButton = BrowserToolbarButton()
    let highlightAllBox = NSButton(checkboxWithTitle: "Highlight All", target: nil, action: nil)
    let matchCaseBox = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    let wholeWordsBox = NSButton(checkboxWithTitle: "Whole Words", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        configureField()
        configureCount()
        configureButtons()
        configureBoxes()
        installStack()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Focuses the query and selects it, so opening the bar over a previous
    /// query replaces it on the first keystroke.
    func focusQuery() {
        window?.makeFirstResponder(queryField)
        queryField.currentEditor()?.selectAll(nil)
    }

    func setCount(_ text: String) {
        countLabel.stringValue = text
    }

    private func configureField() {
        let field = queryField
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Find in page"
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }

    private func configureCount() {
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureButtons() {
        configureGlyph(prevButton, symbol: "chevron.up", help: "Previous match", action: #selector(stepPrevious))
        configureGlyph(nextButton, symbol: "chevron.down", help: "Next match", action: #selector(stepNext))
        configureGlyph(closeButton, symbol: "xmark", help: "Close find bar", action: #selector(closeBar))
    }

    private func configureGlyph(_ button: BrowserToolbarButton, symbol: String, help: String, action: Selector) {
        // Same sizing the toolbar measures: ~18pt glyph in a 24pt frame.
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium))
        button.toolTip = help
        button.target = self
        button.action = action
    }

    private func configureBoxes() {
        for box in [highlightAllBox, matchCaseBox, wholeWordsBox] {
            box.translatesAutoresizingMaskIntoConstraints = false
            box.font = .systemFont(ofSize: 12)
            box.target = self
            box.action = #selector(optionsChanged)
        }
        highlightAllBox.state = .on
    }

    private func installStack() {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        stack.addArrangedSubview(queryField)
        stack.addArrangedSubview(countLabel)
        stack.addArrangedSubview(prevButton)
        stack.addArrangedSubview(nextButton)
        stack.addArrangedSubview(highlightAllBox)
        stack.addArrangedSubview(matchCaseBox)
        stack.addArrangedSubview(wholeWordsBox)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(closeButton)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func stepPrevious() {
        onPrevious?()
    }

    @objc private func stepNext() {
        onNext?()
    }

    @objc private func optionsChanged() {
        onOptionsChanged?()
    }

    @objc private func closeBar() {
        onClose?()
    }
}

extension FindBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(queryField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Shift+Enter steps back; plain Enter steps forward. The field
            // editor owns the key event, so the shift state is read off the
            // current event rather than passed in.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}
