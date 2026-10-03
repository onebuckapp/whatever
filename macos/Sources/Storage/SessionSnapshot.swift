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

        init(
            frame: Frame = .default,
            tabs: [TabSnapshot] = [],
            selectedTabID: UUID? = nil,
            layout: Layout
        ) {
            self.frame = frame
            self.tabs = tabs
            self.selectedTabID = selectedTabID
            self.layout = layout
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

        init(
            id: UUID,
            url: String,
            title: String?,
            isPinned: Bool,
            history: [String],
            historyIndex: Int
        ) {
            self.id = id
            self.url = url
            self.title = title
            self.isPinned = isPinned
            self.history = history
            self.historyIndex = historyIndex
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