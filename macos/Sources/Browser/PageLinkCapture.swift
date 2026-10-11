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

/// Records which link the page's own `contextmenu` event fired on, and which
/// image.
///
/// The menu needs the right-clicked link's address and the right-clicked
/// image's source, and the page knows both exactly: when the user
/// right-clicks, the browser dispatches a `contextmenu` event whose target
/// is the element under the pointer. A capture listener resolves
/// `closest('a[href]')` and `closest('img')` from that target and stores the
/// href and the current source. Reading that beats the old approach of
/// mapping the click's view coordinates back to a CSS point with
/// `elementFromPoint`, which missed whenever the page's layout, scroll
/// container, or zoom did not match the assumption — and a miss made the
/// open-in-new items silently fall back to WebKit's in-place load.
///
/// Injected on every page like the find bridge: tiny, idempotent, and
/// harmless. The values are consumed (cleared) when a menu reads them, so a
/// stale link or image can never leak into a later menu.
@MainActor
enum PageLinkCapture {
    /// The page variable the capture writes and the menu reads.
    static let variable = "__whateverContextLink"
    /// The right-clicked image's source, beside the link above. `currentSrc`
    /// before `src` so responsive images resolve to the variant on screen.
    static let imageVariable = "__whateverContextImage"
    private static let installed = "__whateverContextCapture"

    nonisolated static var source: String {
        """
        (() => {
            if (window.\(installed)) return;
            window.\(installed) = true;
            window.\(variable) = null;
            window.\(imageVariable) = null;
            document.addEventListener('contextmenu', (event) => {
                const target = event.target;
                const anchor = target && target.closest ? target.closest('a[href]') : null;
                window.\(variable) = anchor ? anchor.href : null;
                const img = target && target.closest ? target.closest('img') : null;
                window.\(imageVariable) = img ? (img.currentSrc || img.src) : null;
            }, true);
        })();
        """
    }

    nonisolated static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
