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

import CoreGraphics
import Foundation

/// The whole browser session as one document: every window with its frame, its
/// ordered tabs, and what the page area was showing.
///
/// Stored as a single JSON blob in the `sessions` rdbms store rather than through
/// the `windows` and `tabs` tables `schema.nim` also defines. Those tables exist
/// for querying a session rather than replaying it; a snapshot is always read
/// and written whole, and one row is atomic in a way a multi-table rewrite is
/// not. See `core/nim-core/api/session_api.nim`.
///
/// Private tabs are never here. `BrowserCoordinator` filters them out before
/// building a snapshot, so there is no snapshot content here to decide about.
struct SessionSnapshot: Codable, Equatable {
    var windows: [WindowSnapshot]

    init(windows: [WindowSnapshot] = []) {
        self.windows = windows
    }

    /// Whether there is anything here worth reopening.
    ///
    /// A snapshot of zero windows is written when the user closes every window
    /// while the app keeps running, and that has to mean "start fresh" on the
    /// next launch rather than "restore nothing and sit there".
    var isRestorable: Bool {
        windows.contains { !$0.tabs.isEmpty }
    }

    /// Empty document. What a fresh install reads back, and what is stored when
    /// the last window closes.
    static let empty = SessionSnapshot()

    // MARK: - Window

    struct WindowSnapshot: Codable, Equatable {
        var frame: Frame
        var tabs: [TabSnapshot]
        var selectedTabID: UUID?
        var layout: Layout
        /// The sticky split group, when the window had one — shown or
        /// hidden. Absent in documents written before groups existed, which
        /// decode as no group.
        var splitGroup: Layout?

        init(
            frame: Frame = .default,
            tabs: [TabSnapshot] = [],
            selectedTabID: UUID? = nil,
            layout: Layout,
            splitGroup: Layout? = nil
        ) {
            self.frame = frame
            self.tabs = tabs
            self.selectedTabID = selectedTabID
            self.layout = layout
            self.splitGroup = splitGroup
        }

        /// What the page area was showing: one tab, or two with a divider ratio.
        enum Layout: Codable, Equatable {
            case single(UUID)
            case split(leading: UUID, trailing: UUID, ratio: Double)

            /// The tabs this layout displays, in order.
            var tabIDs: [UUID] {
                switch self {
                case .single(let id):
                    return [id]
                case .split(let leading, let trailing, _):
                    return [leading, trailing]
                }
            }
        }

        /// A window frame in absolute screen coordinates.
        ///
        /// Stored as four doubles rather than a `CGRect` so the document does not
        /// depend on `CGRect`'s own `Codable` conformance, which encodes as an
        /// unkeyed container and is a nuisance to read back by hand.
        struct Frame: Codable, Equatable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double

            /// Matches the size a fresh window is created at.
            static let `default` = Frame(x: 0, y: 0, width: 1300, height: 840)

            init(x: Double, y: Double, width: Double, height: Double) {
                self.x = x
                self.y = y
                self.width = width
                self.height = height
            }

            init(_ rect: CGRect) {
                self.init(
                    x: Double(rect.origin.x),
                    y: Double(rect.origin.y),
                    width: Double(rect.size.width),
                    height: Double(rect.size.height)
                )
            }

            var rect: CGRect {
                CGRect(x: x, y: y, width: width, height: height)
            }

            /// Whether this frame is worth restoring.
            ///
            /// A window restored onto a display that is no longer attached gets
            /// an off-screen frame and looks like the app failed to open, so a
            /// degenerate or absent geometry falls back to letting the window
            /// centre itself.
            var isUsable: Bool {
                width >= 360 && height >= 320 && width.isFinite && height.isFinite
                    && x.isFinite && y.isFinite
            }

            /// Width capped to `limit`: a frame saved while the window was
            /// transiently oversized (the old constraint ratchet, a detached
            /// external display) must not come back and shove the restored
            /// window off a smaller screen. AppKit clamps on show anyway;
            /// this also keeps the session document itself honest.
            func widthCapped(to limit: Double) -> Frame {
                guard width > limit else { return self }
                return Frame(x: x, y: y, width: limit, height: height)
            }
        }
    }

    // MARK: - Tab

    struct TabSnapshot: Codable, Equatable {
        var id: UUID
        var url: String
        var title: String?
        var isPinned: Bool
        /// The tab's own back/forward addresses, oldest first.
        var history: [String]
        /// Where `history` currently sits. Always a valid index when restored.
        var historyIndex: Int
        /// Whether the user silenced this tab, so a restored tab comes back muted.
        ///
        /// Optional because a snapshot written before tab muting existed has no
        /// such key, and Swift's synthesized `Decodable` throws `keyNotFound` for a
        /// missing key even where the property has a default value. Optional
        /// decodes to `nil`, and `nil` means unmuted, which is what those older
        /// documents meant.
        var isMuted: Bool?

        init(
            id: UUID,
            url: String,
            title: String?,
            isPinned: Bool,
            history: [String],
            historyIndex: Int,
            isMuted: Bool? = nil
        ) {
            self.id = id
            self.url = url
            self.title = title
            self.isPinned = isPinned
            self.history = history
            self.historyIndex = historyIndex
            self.isMuted = isMuted
        }

        /// The address the tab was showing.
        var currentURL: URL? {
            guard let resolved = URL(string: url) else { return nil }
            return resolved
        }

        /// The restored history, with anything unparseable dropped.
        ///
        /// Drops the whole tab's history if the current address is missing,
        /// since a tab whose index points at nothing would restore to the
        /// homepage and quietly disagree with the document.
        var restoredURLs: [URL]? {
            guard currentURL != nil else { return nil }
            let urls = history.compactMap { URL(string: $0) }
            guard !urls.isEmpty else { return nil }
            return urls
        }

        /// Clamps the stored index into the stored history.
        var restoredIndex: Int {
            guard let count = restoredURLs?.count, count > 0 else { return 0 }
            return min(max(0, historyIndex), count - 1)
        }
    }
}