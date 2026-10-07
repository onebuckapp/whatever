import AppKit
import MijickPopups
import SwiftUI

/// Centered file browser popup rendered by Mijick/Popups.
///
/// The listing comes from the Nim backend through the `WhateverStore` XPC
/// service; presentation, dismissal, and styling stay here. Pane-scoped like
/// the QR card, so split panes browse independently.
struct FileBrowserPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    let store: FileBrowserStore

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.clear)
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            FileBrowserCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        FileBrowserView(store: store)
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
struct FileBrowserPopupRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let store: FileBrowserStore

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
                await FileBrowserPopup(stackID: stackID, popupID: popupID, store: store)
                    .present(popupStackID: stackID)
            }
    }
}
