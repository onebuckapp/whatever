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

    /// Whether a press alone dismisses, or only a completed click does.
    ///
    /// The legacy behavior (true) fires `onClick` on every press and every
    /// release that reaches the shield. That misfires on releases that merely
    /// fall through to it: a drag starting on the card above is owned by the
    /// card's gesture, and when its release lands outside the card the host
    /// declines it, the deafened page declines it, and the shield is left
    /// holding a release whose press it never saw. With false the shield arms
    /// on press and fires only when the release lands near that press, so
    /// only a genuine click on the shield itself dismisses.
    var dismissOnPress = true

    /// Press position (window coordinates) arming a click while
    /// `dismissOnPress` is false. Nil when no press is outstanding.
    private var pressPoint: NSPoint?

    /// Window movement between press and release that still counts as the
    /// click which dismisses, mirroring the presenter's backdrop guard.
    private static let clickSlop: CGFloat = 6

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
        if dismissOnPress {
            onClick?()
        } else {
            // Arm only. Firing here would dismiss on the mere start of a
            // drag, and a release landing here without its press having done
            // so is a fall-through, not a click (see `dismissOnPress`).
            pressPoint = event.locationInWindow
        }
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
        if dismissOnPress {
            onClick?()
        } else {
            defer { pressPoint = nil }
            guard let press = pressPoint else { return }
            let release = event.locationInWindow
            if hypot(release.x - press.x, release.y - press.y) <= Self.clickSlop {
                onClick?()
            }
        }
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