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

import WebKit

/// Rebuilds a page's user-script list from current settings.
///
/// `WKUserContentController` has no remove-single-script, so every feature
/// toggle rebuilds the whole list: the find bridge, the link capture, and
/// the hover reporter always, then each opt-in script whose setting is on.
/// Message handlers are rebuilt the same way (`removeScriptMessageHandler`
/// before `add` keeps re-adding idempotent). Future loads get exactly this
/// set; each feature separately patches the document already on screen,
/// because a live document keeps its already-evaluated scripts.
@MainActor
enum PageScripts {
    static func rebuild(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(FindBridge.script)
        controller.addUserScript(PageLinkCapture.script)
        controller.addUserScript(LinkHover.script)
        controller.removeScriptMessageHandler(forName: LinkHover.handlerName)
        if let browserView = webView as? BrowserWebView {
            let relay = LinkHoverRelay()
            relay.view = browserView
            browserView.hoverRelay = relay
            controller.add(relay, name: LinkHover.handlerName)
        }
        let settings = SettingsStore.shared.settings
        let background = settings.appearance.background
        if background.isActive && background.showThroughPages {
            controller.addUserScript(PageTransparency.script)
        }
        if settings.search.cleanResultLinks {
            controller.addUserScript(SearchLinkGuard.script)
        }
    }
}
