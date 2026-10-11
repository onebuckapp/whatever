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
import MijickPopups
import SwiftUI
import Testing
@testable import Whatever

/// A left click on empty card space must stay inside the settings dialog.
///
/// The card is a 720x520 body with 88pt of transparent shadow room above
/// and below it, centred in the window. Two layers compete for taps there:
/// the card's own guard, which wins hit-testing (taps resolve to the
/// hosting view, never to anything below it), and Mijick's tap-outside
/// overlay behind it, whose tap fires even for taps the guard wins and
/// would close the dialog the user was trying to click inside. So the
/// guard must claim the card's whole rect *and* Mijick tap-outside must
/// stay off; genuine backdrop clicks still dismiss through the window's
/// modal shield, which only sees what the card does not claim. Right and
/// middle clicks never dismiss anything: tap gestures are left-button-only
/// and the shield swallows the rest.
///
/// The real popup body is hosted directly over a real shield, so this pins
/// the actual modifier chain rather than a copy of it. Mijick's present is
/// deliberately bypassed: it runs through `.task` and never fires without
/// a visible window, and everything under test lives in the card and its
/// configuration.
@MainActor
struct SettingsCardTapTests {
    /// The card's measured size, centred in a 1200x900 window: Mijick does
    /// the same centring when it presents.
    private static let cardFrame = NSRect(x: 240, y: 102, width: 720, height: 696)

    /// Inside the body (the opaque fill always claims these).
    private static let bodyPoint = NSPoint(x: 600, y: 450)
    /// Transparent shadow room above the card (only the tap guard claims these).
    private static let shadowPoint = NSPoint(x: 600, y: 754)
    /// Outer shadow room near the padding edge, past the shadows' bleed
    /// (only the tap guard claims these; the shadows cannot).
    private static let outerShadowPoint = NSPoint(x: 600, y: 790)
    /// Truly outside the dialog (must reach the shield: the dismiss path).
    private static let backdropPoint = NSPoint(x: 60, y: 60)

    @Test("Mijick tap-outside is off for the settings card")
    func tapOutsideDisabled() {
        #expect(SettingsModalPopup.cardPopupConfig(CenterPopupConfig()).isTapOutsideToDismissEnabled == false,
                "Mijick tap-outside fires even for taps the card's guard wins and would close the dialog from its shadow room")
        #expect(SettingsModalPopup.cardStackConfig(GlobalConfigCenter()).isTapOutsideToDismissEnabled == false,
                "the stack default re-enabled Mijick tap-outside for the settings card")
    }

    @Test("the card geometry box matches the live window")
    func cardGeometry() {
        // Values observed in a live 1562x967 window: the monitor and the
        // shield must classify presses against this same box.
        let box = SettingsCardGeometry.box(in: NSRect(x: 0, y: 0, width: 1562, height: 967))
        #expect(box == NSRect(x: 413, y: 127.5, width: 736, height: 712))
    }

    @Test("empty card space is claimed by the card, backdrop still reaches the shield")
    func emptySpaceClaimed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(container)

        // Same layering as the window controller: the shield first, so it
        // sits below the popup host and only sees what the card does not
        // claim.
        let shield = ModalEventShieldView()
        shield.dismissOnPress = false
        shield.frame = container.bounds
        container.addSubview(shield)

        let popup = SettingsModalPopup(
            stackID: PopupStackID(rawValue: "test-\(UUID().uuidString)"),
            popupID: "test",
            section: .general
        )
        let hosting = NSHostingView(rootView: popup.body)
        hosting.frame = Self.cardFrame
        container.addSubview(hosting)
        container.layoutSubtreeIfNeeded()

        let bodyHit = container.hitTest(Self.bodyPoint)
        #expect(bodyHit != nil && bodyHit !== shield,
                "the card body stopped claiming its own taps")

        // Transparent shadow room, mid-strip and past the shadows' bleed:
        // claimed by the card's tap guard, never by the shield below it.
        // Either falling through would hand the click to the shield and
        // close the dialog.
        let shadowHit = container.hitTest(Self.shadowPoint)
        #expect(shadowHit != nil && shadowHit !== shield,
                "a click on the card's shadow room fell through to the shield and would close the dialog")
        let outerHit = container.hitTest(Self.outerShadowPoint)
        #expect(outerHit != nil && outerHit !== shield,
                "a click on the card's outer shadow room fell through to the shield and would close the dialog")

        // A click truly outside the dialog still falls through to the
        // shield, which is the outside-dismissal path.
        #expect(container.hitTest(Self.backdropPoint) === shield,
                "a backdrop click no longer reaches the shield")
    }
}
