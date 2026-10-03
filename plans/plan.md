## Swift macOS Browser Plan

Build it as a native macOS app using SwiftUI for application state and layout, AppKit for native windows/tabs, and `WKWebView` for page rendering.

The key architectural decision is:

- **One browser tab = one `WKWebView`**
- **One native app window = one or more browser tabs**
- **Tabs use `NSWindow`’s native tabbing system**
- **Each tab is represented by a separate `NSWindow`**
- Users can merge windows into tabs, drag tabs out, and create independent windows naturally

This is different from placing multiple pages inside one SwiftUI `TabView`.

## 1. Define the core model

Create a lightweight model for browser-tab state.

```swift
import Foundation

struct BrowserTabState: Identifiable {
    let id: UUID
    var title: String
    var url: URL?
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        url: URL? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}
```

Keep the model independent from `WKWebView`. The web view is an implementation detail owned by a browser window controller.

A useful separation is:

```text
BrowserTabState
    ├── title
    ├── URL
    ├── loading state
    └── navigation state

BrowserTabController
    └── WKWebView

BrowserWindowController
    └── NSWindow
```

## 2. Use one `NSWindow` per browser tab

Although the user sees tabs, each tab should internally be an `NSWindow` with:

```swift
window.tabbingIdentifier = "com.example.browser"
window.tabbingMode = .preferred
```

When multiple windows have the same tabbing identifier, macOS can group them into a native tab bar.

Create a browser window controller:

```swift
import AppKit
import WebKit

final class BrowserWindowController: NSWindowController {
    let webView: WKWebView
    let tabID: UUID

    init(tabID: UUID = UUID(), initialURL: URL? = nil) {
        self.tabID = tabID

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        self.webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        let contentViewController = BrowserViewController(
            webView: webView
        )

        let window = NSWindow(
            contentViewController: contentViewController
        )

        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]

        window.titleVisibility = .visible
        window.tabbingIdentifier = "com.example.browser"
        window.tabbingMode = .preferred
        window.setContentSize(NSSize(width: 1200, height: 800))

        super.init(window: window)

        if let initialURL {
            load(initialURL)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
}
```

`WKWebsiteDataStore.default()` allows normal persistent cookies, cache, and website storage. Later, you can add private browsing with `WKWebsiteDataStore.nonPersistent()`.

## 3. Create the web-view controller

Use an AppKit view controller for the actual browser page. This makes navigation delegates, toolbar actions, and popup handling easier than putting everything directly in SwiftUI.

```swift
import AppKit
import WebKit

final class BrowserViewController: NSViewController {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
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

Start with AppKit for the browser content. You can add a SwiftUI toolbar later using `NSHostingView`.

## 4. Add a browser coordinator

You need a central object to create, track, focus, and close browser windows.

```swift
import AppKit
import WebKit

@MainActor
final class BrowserCoordinator: NSObject, ObservableObject {
    static let shared = BrowserCoordinator()

    private(set) var windows: [BrowserWindowController] = []

    @discardableResult
    func newTab(
        url: URL? = URL(string: "https://www.example.com"),
        attachedTo parent: NSWindow? = nil
    ) -> BrowserWindowController {
        let controller = BrowserWindowController(initialURL: url)
        windows.append(controller)

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        if let parent,
           let childWindow = controller.window {
            parent.addTabbedWindow(childWindow, ordered: .above)
            parent.selectNextTab(nil)
        }

        return controller
    }

    func close(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        controller.close()
    }
}
```

For an actual application, observe `NSWindow.willCloseNotification` and remove closed windows automatically:

```swift
NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification,
    object: nil,
    queue: .main
) { [weak self] notification in
    guard let window = notification.object as? NSWindow else {
        return
    }

    self?.windows.removeAll {
        $0.window === window
    }
}
```

Avoid relying exclusively on a SwiftUI `@State` array for windows. Native window tabbing and tab dragging are controlled by AppKit, so AppKit should remain the source of truth for window lifetime.

## 5. Support New Tab

Add a native menu command for `⌘T`.

```swift
@main
struct BrowserApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("New Tab") {
                    let keyWindow = NSApp.keyWindow

                    BrowserCoordinator.shared.newTab(
                        attachedTo: keyWindow
                    )
                }
                .keyboardShortcut("t", modifiers: [.command])
            }
        }
    }
}
```

When the key window is already part of a tab group, calling:

```swift
keyWindow?.addTabbedWindow(newWindow, ordered: .above)
```

adds the new browser page as a native tab.

You should also support:

- `⌘W` — close current tab
- `⌘⇧T` — reopen closed tab
- `⌘1` through `⌘9` — select tab
- `⌘⇧[` and `⌘⇧]` — previous/next tab
- Window menu actions supplied by macOS

## 6. Handle navigation

Implement `WKNavigationDelegate` to update the tab title, URL, loading state, and navigation buttons.

```swift
extension BrowserViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        webView.window?.title = "Loading…"
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        webView.window?.title = webView.title ?? "New Tab"
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        webView.window?.title = "Failed to Load"
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}
```

Assign the delegate during setup:

```swift
webView.navigationDelegate = self
```

A more complete implementation should use a separate observable `BrowserTabController` so the toolbar can react to:

```swift
webView.url
webView.title
webView.isLoading
webView.canGoBack
webView.canGoForward
```

## 7. Handle links that request new windows

Sites may use:

```javascript
window.open(...)
```

or links with:

```html
target="_blank"
```

Implement `WKUIDelegate` and convert those requests into new browser tabs.

```swift
extension BrowserViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }

        let newController = BrowserCoordinator.shared.newTab(
            url: url,
            attachedTo: webView.window
        )

        return newController.webView
    }
}
```

In practice, you may need to return the newly created web view and let WebKit perform the navigation itself:

```swift
func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
) -> WKWebView? {
    let newController = BrowserCoordinator.shared.newTab(
        url: nil,
        attachedTo: webView.window
    )

    return newController.webView
}
```

Then make sure the new tab is navigated by WebKit. This method is important because otherwise popup links may do nothing.

## 8. Support dragged-out tabs

Native macOS window tabbing provides most of this automatically:

- A tab can be dragged out of a tab group.
- The dragged tab becomes its own window.
- A window can be dragged onto another browser window.
- Windows with the same tabbing identifier can be merged.

Do not manually implement drag-and-drop for the tab bar initially. Let `NSWindow` handle it.

Your responsibility is to ensure that each tab window remains self-contained:

```text
Tab window
    ├── WKWebView
    ├── navigation delegate
    ├── UI delegate
    ├── tab title
    ├── current URL
    └── session-specific state
```

Do not store the active `WKWebView` globally. If a tab is dragged to a new window, its web view should remain associated with that window.

## 9. Add the browser toolbar

Use an `NSToolbar` or SwiftUI hosted in the title bar.

Recommended initial layout:

```text
Back | Forward | Reload | Address field | Share | Downloads
```

For a native AppKit toolbar:

```swift
final class BrowserToolbarDelegate: NSObject, NSToolbarDelegate {
    static let backIdentifier = NSToolbarItem.Identifier("back")
    static let forwardIdentifier = NSToolbarItem.Identifier("forward")
    static let reloadIdentifier = NSToolbarItem.Identifier("reload")
    static let addressIdentifier = NSToolbarItem.Identifier("address")

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.backIdentifier:
            let item = NSToolbarItem(
                itemIdentifier: itemIdentifier
            )
            item.label = "Back"
            item.image = NSImage(
                systemSymbolName: "chevron.left",
                accessibilityDescription: "Back"
            )
            return item

        default:
            return nil
        }
    }
}
```

For a first version, a SwiftUI toolbar embedded in the window’s content controller is simpler and easier to iterate on.

## 10. Build the address field carefully

The address field needs two modes:

1. **URL mode** — load a URL.
2. **Search mode** — send non-URL text to a search engine.

Create a URL parser:

```swift
enum AddressParser {
    static func url(
        from input: String,
        searchBaseURL: URL
    ) -> URL? {
        let text = input.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if let url = URL(string: text),
           url.scheme != nil {
            return url
        }

        if let url = URL(string: "https://\(text)"),
           text.contains(".") {
            return url
        }

        var components = URLComponents(
            url: searchBaseURL,
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [
            URLQueryItem(name: "q", value: text)
        ]

        return components?.url
    }
}
```

Do not inject arbitrary text directly into a URL request. Validate the scheme and normalize the input first.

## 11. Add history and bookmarks after navigation works

Do not begin with a database. First make navigation reliable.

Then add:

### History

Store:

```swift
struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let visitedAt: Date
}
```

Use SQLite, SwiftData, or a simple JSON store for the first prototype.

### Bookmarks

Store:

```swift
struct Bookmark: Codable, Identifiable {
    let id: UUID
    var title: String
    var url: URL
    var folderID: UUID?
}
```

### Session restoration

Save:

- Open tab URLs
- Tab titles
- Window frames
- Window grouping
- Selected tab
- Private/non-private status

Restore only after the app has a stable window lifecycle.

## 12. Handle downloads

Implement `WKDownloadDelegate` for downloads initiated by WebKit.

You will need to handle:

- Suggested filename
- Destination URL
- Duplicate filenames
- Download cancellation
- Download failure
- Download progress
- A downloads popover or downloads window

Keep downloads outside the tab model. A download can continue after its originating tab closes.

```text
DownloadManager
    ├── active downloads
    ├── completed downloads
    ├── destination folder
    └── progress notifications
```

## 13. Handle permissions and browser dialogs

Plan for:

- JavaScript alert dialogs
- JavaScript confirmation dialogs
- JavaScript prompt dialogs
- Camera permission
- Microphone permission
- Geolocation permission
- Notifications
- File upload panels
- Pop-up windows
- HTTP authentication

Implement `WKUIDelegate` for JavaScript dialogs and file uploads. Add the required usage descriptions to the app’s `Info.plist` only when those capabilities are actually supported.

## 14. Add private browsing as a separate mode

Private tabs should use a nonpersistent data store:

```swift
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
```

Private tabs should not share:

- Cookies
- Local storage
- Cache
- Website permissions
- Session restoration data
- History

Represent this explicitly:

```swift
enum BrowserPrivacyMode {
    case regular
    case privateBrowsing
}
```

Avoid switching a web view between persistent and nonpersistent modes. Create the web view with the correct configuration from the beginning.

## 15. Suggested project structure

```text
BrowserApp/
├── App/
│   ├── BrowserApp.swift
│   └── AppCommands.swift
├── Browser/
│   ├── BrowserCoordinator.swift
│   ├── BrowserWindowController.swift
│   ├── BrowserViewController.swift
│   ├── BrowserTabState.swift
│   ├── BrowserTabController.swift
│   └── BrowserPrivacyMode.swift
├── Navigation/
│   ├── NavigationController.swift
│   ├── AddressParser.swift
│   └── NavigationPolicy.swift
├── Storage/
│   ├── HistoryStore.swift
│   ├── BookmarkStore.swift
│   └── SessionStore.swift
├── Downloads/
│   └── DownloadManager.swift
├── UI/
│   ├── BrowserToolbar.swift
│   ├── AddressField.swift
│   └── DownloadsView.swift
└── Resources/
    └── Assets.xcassets
```

## 16. Recommended implementation phases

### Phase 1: One working browser window

Implement:

- `WKWebView`
- URL loading
- Back and forward
- Reload
- Page title
- Loading indicator
- Basic address field

Goal: load normal websites reliably.

### Phase 2: Native tabs

Implement:

- One `NSWindow` per tab
- Shared `tabbingIdentifier`
- `⌘T`
- `⌘W`
- Native tab dragging
- New-window creation
- Tab title updates

Goal: tabs can be merged, detached, and independently navigated.

### Phase 3: Web compatibility

Implement:

- `WKUIDelegate`
- `target="_blank"`
- JavaScript popups
- File uploads
- Authentication dialogs
- Redirect and navigation policies
- Error pages

Goal: common websites behave like they do in a normal browser.

### Phase 4: Browser essentials

Implement:

- History
- Bookmarks
- Downloads
- Search-engine selection
- Session restoration
- Reopen closed tab
- Find in page

### Phase 5: Privacy modes and polish

Implement:

- Private browsing
- Website data clearing
- Per-site permissions
- Tab previews
- Reader mode, if desired
- Crash recovery
- Accessibility
- Keyboard shortcuts
- VoiceOver labels

## 17. Important design constraints

Use `NSWindow` tabbing rather than `TabView` because you want tabs to detach into windows.

Do not recreate a `WKWebView` when a tab is dragged out. The same tab window should continue owning the same web view.

Do not put all browser state in one global singleton. A coordinator can manage windows, but each tab should own its navigation state.

Do not use a single shared `WKWebsiteDataStore` for private and regular tabs.

Do not assume that every new-window request should become a tab. Later, add a preference for:

```swift
enum NewWindowBehavior {
    case newTab
    case newWindow
    case block
}
```

The first milestone should be a small browser with one `WKWebView` per native tab window, native `NSWindow` tabbing, and correct handling of `target="_blank"`. Once that foundation works, history, downloads, private browsing, and session restoration can be added without redesigning the tab architecture.