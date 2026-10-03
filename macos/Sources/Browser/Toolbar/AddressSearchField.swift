import AppKit

/// Address search field: clicking into it selects the entire address.
///
/// Selecting in `controlTextDidBeginEditing` is not enough — that fires on
/// mouse-down, and the following mouse-up then places the caret and clears
/// the selection. So a plain first click that focuses the field re-selects
/// everything on mouse-up instead. Clicks when already focused, double
/// clicks, and drags keep their normal caret/word/range behavior.
final class AddressSearchField: NSSearchField {
    private var mouseDownLocation: NSPoint?
    private var wasFocusedOnMouseDown = false

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        wasFocusedOnMouseDown = window?.firstResponder === currentEditor()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)

        guard !wasFocusedOnMouseDown, event.clickCount == 1 else { return }
        if let down = mouseDownLocation {
            let up = convert(event.locationInWindow, from: nil)
            guard hypot(up.x - down.x, up.y - down.y) < 3 else { return }
        }
        currentEditor()?.selectAll(nil)
    }
}
