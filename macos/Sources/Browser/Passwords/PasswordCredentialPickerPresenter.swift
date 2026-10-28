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

/// Inline credential picker: an `NSPopover` anchored under the focused
/// login field, listing the vault's matching credentials.
///
/// Transient, so any outside click dismisses it without extra monitors.
/// One presenter per pane, owned by the pane next to the suggest presenter.
/// The pane owns matching and filling; this only shows the rows and reports
/// the pick back. Row titles reuse the context-menu rule
/// (`PasswordAutofill.menuTitle`), so the menu and the picker name a
/// credential the same way.
@MainActor
final class PasswordCredentialPickerPresenter: NSObject {
    private var popover: NSPopover?

    var isPresented: Bool {
        popover != nil
    }

    /// Shows matching credentials, replacing any already-visible picker.
    /// A second focus while open lays out fresh rather than stacking.
    func present(
        anchorRect: NSRect,
        in view: NSView,
        matches: [PasswordAutofill.Match],
        showsManage: Bool,
        onPick: @escaping (PasswordAutofill.Match) -> Void,
        onManage: @escaping () -> Void
    ) {
        dismiss()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let content = PasswordCredentialPicker(
            matches: matches,
            showsManage: showsManage,
            onPick: { [weak self] match in
                onPick(match)
            },
            onManage: { [weak self] in
                onManage()
            }
        )
        popover.contentViewController = NSHostingController(rootView: content)
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
    }

    /// Shows the locked single row, which opens the manager to unlock.
    /// Offered on login-field focus while the vault is locked, so an
    /// autofill is one row away instead of a hunt through the menus.
    func presentLocked(
        anchorRect: NSRect,
        in view: NSView,
        onUnlock: @escaping () -> Void
    ) {
        dismiss()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let content = PasswordCredentialUnlockRow(onUnlock: { [weak self] in
            onUnlock()
        })
        popover.contentViewController = NSHostingController(rootView: content)
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
    }

    func dismiss() {
        popover?.close()
        popover = nil
    }
}

extension PasswordCredentialPickerPresenter: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}

/// The picker's credential rows, capped like the context-menu submenu.
private struct PasswordCredentialPicker: View {
    let matches: [PasswordAutofill.Match]
    let showsManage: Bool
    let onPick: (PasswordAutofill.Match) -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(matches, id: \.credential.id) { match in
                Button {
                    onPick(match)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(PasswordAutofill.menuTitle(for: match))
                                .font(.system(size: 13))
                                .lineLimit(1)
                            if showsSite(for: match) {
                                Text(match.siteName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if showsManage {
                Divider()
                Button(tr("Manage Passwords...", ctx: "Context.Page")) {
                    onManage()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 280)
    }

    /// Names the site under the username only when several sites share the
    /// picker, so two `admin` rows stay distinguishable.
    private func showsSite(for match: PasswordAutofill.Match) -> Bool {
        Set(matches.map(\.siteID)).count > 1
    }
}

/// The locked single row.
private struct PasswordCredentialUnlockRow: View {
    let onUnlock: () -> Void

    var body: some View {
        Button {
            onUnlock()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(tr("Unlock Passwords...", ctx: "Passwords"))
                    .font(.system(size: 13))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 240)
    }
}
