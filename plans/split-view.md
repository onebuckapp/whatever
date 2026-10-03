## Split-view tab plan

> **Superseded in part.** The original design built split panes inside a
> native `NSWindow` tab. The tab bar is now a custom AppKit strip above
> the window content, so a window owns an ordered list of `BrowserTab`s
> and the split layout is a separate presentation state
> (`BrowserWindowController.ContentLayout`). Statements below about
> "native `NSWindow` tab", `tabbingIdentifier`, and `selectNextTab` no
> longer describe the code. The split model, pane retention, and
> transaction rules still apply.

Add a split-view layer inside each browser window.

The architecture becomes:

```text
Native NSWindow tab
└── BrowserTabWindowController
    └── BrowserSplitViewController
        ├── BrowserPaneController
        │   └── WKWebView
        ├── BrowserPaneController
        │   └── WKWebView
        └── Additional panes...
```

Each pane owns its own `WKWebView`, navigation state, URL, and browser history context. The native window tab remains the outer container, while the split view controls multiple pages inside that tab.

```text
Window tab
    ├── Split layout
    │   ├── Tab/page A
    │   └── Tab/page B
    │
    └── Can be dragged out as one window
```

## Important distinction

A native `NSWindow` tab cannot directly display two independent tab contents side by side. It normally represents one window content hierarchy.

Therefore, when two tabs are merged into a split view, the application should:

1. Take the two browser sessions.
2. Remove them from their individual window controllers.
3. Insert their `WKWebView` instances into a shared split container.
4. Treat the result as one composite browser tab.
5. Keep each pane independently navigable.

The `WKWebView` objects should be moved, not recreated, so cookies, page state, JavaScript state, and scroll positions are preserved.

## Model the layout separately

Create a model for a split browser tab:

```swift
import Foundation

struct BrowserSplitState: Identifiable {
    let id: UUID
    var panes: [BrowserPaneState]
    var orientation: SplitOrientation
    var dividerPositions: [CGFloat]

    init(
        id: UUID = UUID(),
        panes: [BrowserPaneState] = [],
        orientation: SplitOrientation = .vertical,
        dividerPositions: [CGFloat] = []
    ) {
        self.id = id
        self.panes = panes
        self.orientation = orientation
        self.dividerPositions = dividerPositions
    }
}

enum SplitOrientation: String, Codable {
    case vertical
    case horizontal
}

struct BrowserPaneState: Identifiable {
    let id: UUID
    var title: String
    var url: URL?
    var isActive: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        url: URL? = nil,
        isActive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isActive = isActive
    }
}
```

For the first version, support only vertical splitting:

```text
┌──────────────────────┬──────────────────────┐
│                      │                      │
│      Web view A      │      Web view B      │
│                      │                      │
└──────────────────────┴──────────────────────┘
```

Later, add horizontal splitting:

```text
┌─────────────────────────────────────────────┐
│                 Web view A                  │
├─────────────────────────────────────────────┤
│                 Web view B                  │
└─────────────────────────────────────────────┘
```

## Use `NSSplitViewController`

For an AppKit-based browser, `NSSplitViewController` is the appropriate container.

```swift
import AppKit

final class BrowserSplitViewController: NSSplitViewController {
    private(set) var panes: [BrowserPaneController] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
    }

    func addPane(_ pane: BrowserPaneController) {
        let item = NSSplitViewItem(viewController: pane)

        item.canCollapse = false
        item.minimumThickness = 240

        addSplitViewItem(item)
        panes.append(pane)
    }

    func removePane(_ pane: BrowserPaneController) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else {
            return
        }

        removeSplitViewItem(at: index)
        panes.remove(at: index)
    }
}
```

Each pane controller owns one `WKWebView`:

```swift
final class BrowserPaneController: NSViewController {
    let paneID: UUID
    let webView: WKWebView

    init(
        paneID: UUID = UUID(),
        webView: WKWebView
    ) {
        self.paneID = paneID
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
```

## Horizontal resizing

`NSSplitView` provides the divider automatically. When the user drags the divider, one pane becomes wider and the other becomes smaller.

You can control the minimum sizes:

```swift
extension BrowserSplitViewController: NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let minimumWidth: CGFloat = 240
        let maximumWidth = splitView.bounds.width - minimumWidth

        return min(
            max(proposedPosition, minimumWidth),
            maximumWidth
        )
    }
}
```

For multiple panes, use the divider index:

```swift
func splitView(
    _ splitView: NSSplitView,
    constrainSplitPosition proposedPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
) -> CGFloat {
    let minimumPaneWidth: CGFloat = 220

    let lowerBound = CGFloat(dividerIndex + 1) * minimumPaneWidth
    let upperBound =
        splitView.bounds.width
        - CGFloat(splitView.subviews.count - dividerIndex - 1)
        * minimumPaneWidth

    return min(
        max(proposedPosition, lowerBound),
        upperBound
    )
}
```

Set the delegate:

```swift
splitView.delegate = self
```

The `minimumThickness` value on each `NSSplitViewItem` should also be set so that a pane cannot become unusably narrow.

## Merging two browser tabs into one split view

Add a command such as:

```text
Window → Move Tab to Split View
```

The operation should look like this:

```swift
func mergeIntoSplitView(
    source: BrowserPaneController,
    target: BrowserPaneController
) {
    let splitController = BrowserSplitViewController()

    splitController.addPane(target)
    splitController.addPane(source)

    // Replace the current window content with splitController.
}
```

In a real implementation, you will need a browser-session layer so the pane controllers can be detached from their existing windows safely.

Use a coordinator method:

```swift
@MainActor
func merge(
    pane source: BrowserPaneController,
    with target: BrowserPaneController,
    in window: NSWindow
) {
    let splitController: BrowserSplitViewController

    if let existing = window.contentViewController
        as? BrowserSplitViewController {
        splitController = existing
    } else {
        splitController = BrowserSplitViewController()
        window.contentViewController = splitController
    }

    splitController.addPane(target)
    splitController.addPane(source)
}
```

The production version should not use the old browser window’s entire content controller. Move only the pane/session into the split controller.

## Session architecture

Separate browser sessions from window controllers:

```text
BrowserSession
    ├── session ID
    ├── WKWebView
    ├── current URL
    ├── page title
    ├── navigation state
    └── privacy mode

BrowserPaneController
    └── displays BrowserSession

BrowserSplitViewController
    └── arranges BrowserPaneControllers

BrowserWindowController
    └── owns the native window
```

Example:

```swift
@MainActor
final class BrowserSession {
    let id: UUID
    let webView: WKWebView

    var title: String = "New Tab"
    var url: URL?

    init(
        id: UUID = UUID(),
        webView: WKWebView
    ) {
        self.id = id
        self.webView = webView
    }
}
```

This makes it possible to move a session between:

- A standalone window
- A native window tab
- A split pane
- A newly created window after detaching

## Splitting a current tab

Add browser commands:

```text
Split Right
Split Down
Close Split
Focus Left Pane
Focus Right Pane
Swap Panes
Move Pane to New Window
```

A split-right command:

```swift
func splitCurrentPaneRight() {
    guard let currentPane = activePane else {
        return
    }

    let newSession = BrowserSession(
        webView: makeWebView()
    )

    let newPane = BrowserPaneController(
        webView: newSession.webView
    )

    splitController.addPane(newPane)
    focus(newPane)
}
```

Load a new-tab page in the newly created pane:

```swift
newSession.webView.load(
    URLRequest(url: URL(string: "about:blank")!)
)
```

## Moving a pane to a new window

A pane can be detached from the split view and placed into a new native window:

```swift
func movePaneToNewWindow(
    _ pane: BrowserPaneController
) {
    splitController.removePane(pane)

    let windowController = BrowserWindowController(
        paneController: pane
    )

    BrowserCoordinator.shared.register(windowController)

    windowController.showWindow(nil)
    windowController.window?.makeKeyAndOrderFront(nil)
}
```

If only one pane remains, simplify the original window back to a normal browser window:

```swift
if splitController.panes.count == 1 {
    replaceSplitViewWithSinglePane()
}
```

This gives you both behaviors:

```text
Split pane dragged or moved out
        ↓
New native NSWindow
        ↓
Can be merged into another native tab later
```

## Dragging tabs into split view

There are two possible approaches.

### Option 1: Native window tabs plus commands

Use native `NSWindow` tabs for window-level tab behavior and provide explicit split commands:

```text
Right-click tab → Move Tab to Split View
Right-click tab → Split Tab Right
```

This is the simplest and most reliable first version.

### Option 2: Custom drag-and-drop

If you want users to drag one tab onto another pane, you will need a custom tab representation or tab overview. Native `NSWindow` tabs do not provide a general API for dropping one native tab directly into another tab’s content area.

A custom interaction could support:

```text
Drag tab
    ├── Drop on left edge  → split left
    ├── Drop on right edge → split right
    ├── Drop on top edge   → split above
    ├── Drop on bottom     → split below
    └── Drop outside       → create a new window
```

However, custom drag handling should be added after the basic split commands work.

## SwiftUI integration

Keep the split container in AppKit, but embed SwiftUI browser controls above each pane.

```swift
struct PaneToolbar: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .lineLimit(1)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }
}
```

Host it inside `BrowserPaneController`:

```swift
let toolbar = NSHostingView(
    rootView: PaneToolbar(
        title: session.title,
        onClose: closePane
    )
)
```

The pane layout becomes:

```text
BrowserSplitViewController
└── BrowserPaneController
    ├── SwiftUI pane toolbar
    └── WKWebView
```

## Nim backend additions

Nim should store split layouts, but not manipulate `NSSplitView` or `WKWebView`.

Add a session layout model:

```nim
type
  SplitOrientation* = enum
    soVertical
    soHorizontal

  BrowserPaneState* = object
    id*: string
    url*: string
    title*: string

  BrowserSplitState* = object
    id*: string
    orientation*: SplitOrientation
    panes*: seq[BrowserPaneState]
    dividerPositions*: seq[float]
```

Persist:

- Split group ID
- Pane IDs
- Pane order
- Pane URLs
- Pane titles
- Orientation
- Divider positions
- Active pane
- Window association

Swift owns the live UI layout:

```text
User drags divider
    ↓
NSSplitView changes position
    ↓
Swift reads divider position
    ↓
Swift sends layout update to Nim
    ↓
Nim persists the session layout
```

For performance, debounce layout saves rather than saving on every pixel of divider movement:

```swift
final class SplitLayoutSaver {
    private var workItem: DispatchWorkItem?

    func scheduleSave(_ state: BrowserSplitState) {
        workItem?.cancel()

        let item = DispatchWorkItem {
            // Send state to Nim backend.
        }

        workItem = item

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.3,
            execute: item
        )
    }
}
```

## Updated milestone

Implement split views in this order:

1. One browser window containing two `WKWebView` panes.
2. Horizontal divider resizing.
3. Minimum pane widths.
4. Add and remove panes.
5. Focus and close-pane commands.
6. Convert two standalone browser sessions into one split view.
7. Move a pane into a new native window.
8. Save and restore split layouts through Nim.
9. Add vertical and horizontal split commands.
10. Add custom drag-to-split behavior.

The recommended final architecture is:

```text
NSWindow native tab
└── BrowserWindowController
    └── BrowserSplitViewController
        ├── BrowserPaneController
        │   ├── SwiftUI pane controls
        │   └── WKWebView
        ├── BrowserPaneController
        │   ├── SwiftUI pane controls
        │   └── WKWebView
        └── Optional additional panes
```

This preserves native macOS tabs while allowing two or more independent browser sessions to share one tabbed window and resize horizontally through draggable split dividers.