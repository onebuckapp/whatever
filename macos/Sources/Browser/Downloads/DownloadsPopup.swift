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

/// Centered downloads popup rendered by Mijick/Popups.
///
/// History comes from the Nim backend through the `WhateverStore` XPC
/// service; presentation, dismissal, and styling stay here. Pane-scoped like
/// the file browser, so the card centers on the page it was opened over.
struct DownloadsPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    let store: DownloadsStore

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.clear)
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            DownloadsCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        DownloadsView(store: store)
            .onExitCommand {
                Task {
                    await PopupStack.dismissPopup(popupID, popupStackID: stackID)
                }
            }
    }
}

/// Root view hosted inside the active page area.
///
/// It fills the page container so Mijick centers the popup on the webpage,
/// then presents the popup once the registered stack is on screen.
struct DownloadsPopupRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let store: DownloadsStore

    var body: some View {
        Color.clear
            .registerPopups(id: stackID) { config in
                config.center { popup in
                    popup
                        .backgroundColor(.clear)
                        .cornerRadius(20)
                        .overlayColor(.clear)
                        .tapOutsideToDismissPopup(true)
                }
            }
            .task {
                await DownloadsPopup(stackID: stackID, popupID: popupID, store: store)
                    .present(popupStackID: stackID)
            }
    }
}
