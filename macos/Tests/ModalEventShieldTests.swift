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
import Testing
@testable import Whatever

/// The modal shield blocks page input while a card is up, but only the
/// left button dismisses: right/middle presses are context menus and
/// gestures of their own. Right-clicking empty card space reaches the
/// shield — SwiftUI tap gestures do not claim the right button, so
/// hit-testing falls straight through the hosting view — and must be
/// swallowed, not treated as a dismissal.
@MainActor
struct ModalEventShieldTests {
    private func press(_ type: NSEvent.EventType, at location: NSPoint = NSPoint(x: 10, y: 10)) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test("left press dismisses, right and middle presses do not")
    func dismissalButtons() {
        let shield = ModalEventShieldView()
        var clicks = 0
        shield.onClick = { clicks += 1 }

        shield.mouseDown(with: press(.leftMouseDown))
        #expect(clicks == 1)

        shield.rightMouseDown(with: press(.rightMouseDown))
        shield.otherMouseDown(with: press(.otherMouseDown))
        #expect(clicks == 1)
    }

    @Test("release-only dismissal still ignores other buttons")
    func releaseModeButtons() {
        let shield = ModalEventShieldView()
        shield.dismissOnPress = false
        var clicks = 0
        shield.onClick = { clicks += 1 }

        shield.rightMouseDown(with: press(.rightMouseDown))
        shield.otherMouseDown(with: press(.otherMouseDown))
        shield.mouseUp(with: press(.leftMouseUp))
        #expect(clicks == 0)

        shield.mouseDown(with: press(.leftMouseDown))
        shield.mouseUp(with: press(.leftMouseUp))
        #expect(clicks == 1)
    }

    @Test("presses inside the exclusion box never arm or fire")
    func exclusionBox() {
        // A window so window-to-view conversion is real: the box lives in
        // the shield's own coordinates.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView?.addSubview(container)
        let shield = ModalEventShieldView()
        shield.dismissOnPress = false
        shield.frame = container.bounds
        container.addSubview(shield)
        shield.exclusionProvider = { NSRect(x: 100, y: 100, width: 200, height: 200) }
        var clicks = 0
        shield.onClick = { clicks += 1 }

        // Press and release inside the box: a routing leak, dies silently.
        shield.mouseDown(with: press(.leftMouseDown, at: NSPoint(x: 200, y: 200)))
        shield.mouseUp(with: press(.leftMouseUp, at: NSPoint(x: 200, y: 200)))
        #expect(clicks == 0)

        // Press and release outside the box: a genuine backdrop click.
        shield.mouseDown(with: press(.leftMouseDown, at: NSPoint(x: 10, y: 10)))
        shield.mouseUp(with: press(.leftMouseUp, at: NSPoint(x: 10, y: 10)))
        #expect(clicks == 1)

        // Press outside, release inside: a drag ending over the card.
        shield.mouseDown(with: press(.leftMouseDown, at: NSPoint(x: 10, y: 10)))
        shield.mouseUp(with: press(.leftMouseUp, at: NSPoint(x: 200, y: 200)))
        #expect(clicks == 1)
    }
}
