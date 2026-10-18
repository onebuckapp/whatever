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
import SwiftUI

/// Floating suggest panel: an `NSPopover` anchored at the right-clicked
/// password field, hosting the shared generator with a Fill button.
///
/// Transient, so any outside click dismisses it without extra monitors.
/// One presenter per pane, owned by the pane next to its other popup
/// presenters. The pane owns filling, copying, and saving; this only shows
/// the panel and reports the chosen password back.
@MainActor
final class PasswordSuggestPresenter: NSObject {
    private var popover: NSPopover?
    private var onDidDismiss: (() -> Void)?

    var isPresented: Bool {
        popover != nil
    }

    /// Shows the panel, replacing any already-visible one (a second click
    /// starts a fresh suggestion rather than stacking).
    func present(
        anchorRect: NSRect,
        in view: NSView,
        wordlist: [String],
        vaultUnlocked: Bool,
        onUse: @escaping (String) -> Void,
        onDidDismiss: (() -> Void)? = nil
    ) {
        dismiss()
        self.onDidDismiss = onDidDismiss
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let content = PasswordSuggestPanel(
            wordlist: wordlist,
            vaultUnlocked: vaultUnlocked,
            onUse: { [weak self] password in
                onUse(password)
            }
        )
        let hosting = NSHostingController(rootView: content)
        hosting.view.frame.size = NSSize(width: 320, height: 320)
        popover.contentViewController = hosting
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
    }

    func dismiss() {
        popover?.close()
        popover = nil
    }

    private func tearDown() {
        popover = nil
        let notify = onDidDismiss
        onDidDismiss = nil
        notify?()
    }
}

extension PasswordSuggestPresenter: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        tearDown()
    }
}

/// The popover body: a header, the shared generator with a Fill button,
/// and a save footnote when the vault is locked.
private struct PasswordSuggestPanel: View {
    let wordlist: [String]
    let vaultUnlocked: Bool
    let onUse: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Suggest a password", ctx: "Passwords"))
                .font(.system(size: 13, weight: .semibold))
            PasswordGeneratorPanel(
                wordlist: wordlist,
                onUse: onUse,
                confirmTitle: tr("Fill", ctx: "Passwords")
            )
            if !vaultUnlocked {
                Text(tr("Unlock Passwords to save it.", ctx: "Passwords"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
