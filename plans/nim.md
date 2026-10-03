```text
Swift / SwiftUI / AppKit
    ├── Application lifecycle
    ├── Native windows and tabs
    ├── Browser toolbar
    ├── Address field
    ├── Bookmarks and history UI
    ├── Download UI
    ├── Settings and preferences
    └── WKWebView integration

WKWebView
    ├── Page rendering
    ├── Navigation
    ├── JavaScript execution
    ├── Cookies and website storage
    ├── JavaScript dialogs
    ├── File uploads
    └── Web permissions

Nim backend
    ├── Browser history storage
    ├── Bookmark storage
    ├── Session restoration
    ├── Download management
    ├── Search-engine configuration
    ├── Browser settings
    ├── URL and navigation utilities
    ├── Content filtering
    ├── Permission storage
    └── Application data management
```

### Swift–Nim boundary

Swift and Nim should communicate through a small, stable C-compatible interface rather than exposing Nim-specific types directly to Swift.

Use Nim’s C code generation:

```nim
proc browser_history_add(
  url: cstring,
  title: cstring,
  timestamp: int64
) {.exportc, dynlib.}
```

Swift can expose this through a bridging header:

```c
const char *browser_history_add(
    const char *url,
    const char *title,
    int64_t timestamp
);
```

Then call it from Swift:

```swift
browser_history_add(
    urlString,
    titleString,
    Int64(Date().timeIntervalSince1970)
)
```

The preferred boundary types should be simple C-compatible values:

- `Int32`
- `Int64`
- `Double`
- `Bool`
- UTF-8 strings
- Byte buffers
- Opaque handles
- Callback functions

Avoid passing these directly across the boundary:

- Swift classes
- Swift structs
- Swift enums
- `WKWebView`
- `NSWindow`
- `URL`
- Swift closures without a C-compatible wrapper
- Nim garbage-collected objects

Convert values at the boundary:

```swift
let urlString = url.absoluteString
let titleString = title
```

## Recommended integration strategy

Start with a static Nim library linked into the macOS application:

```text
Swift app
    └── libbrowsercore.a
```

This is the simplest architecture for a first version:

- Easy distribution
- No separate backend process
- Fast function calls
- Shared application lifecycle
- Simple Xcode integration

A later version can move Nim into an XPC service if the backend becomes large or needs isolation:

```text
Swift application
    └── BrowserCore.xpc
            └── Nim backend
```

Use XPC when you need:

- Fault isolation
- Long-running downloads
- Heavy indexing
- Independent backend updates
- Better separation between UI and services

For the initial implementation, use an embedded Nim library and keep all calls short and non-blocking.

## Suggested backend modules in Nim

```text
nim-core/
├── browsercore.nim
├── api/
│   ├── history_api.nim
│   ├── bookmark_api.nim
│   ├── session_api.nim
│   └── download_api.nim
├── storage/
│   ├── database.nim
│   ├── migrations.nim
│   └── models.nim
├── navigation/
│   ├── url_parser.nim
│   ├── search_engine.nim
│   └── navigation_policy.nim
├── downloads/
│   ├── download_store.nim
│   └── download_rules.nim
└── config/
    └── preferences.nim
```

Swift should own UI-related behavior, while Nim should own persistent browser data and business logic.

For example:

```text
Swift:
    User enters a URL
        ↓
    WKWebView starts navigation
        ↓
    Swift receives page title and final URL
        ↓
    Swift calls Nim history API
        ↓
    Nim stores the history entry
```

## Async communication

Nim operations must not block the main Swift thread. File access, database work, history queries, and download bookkeeping should execute asynchronously.

Swift-facing methods can use completion handlers:

```swift
historyStore.add(
    url: url,
    title: title
) { result in
    // Update UI if necessary
}
```

Internally, the call can dispatch work away from the main thread:

```swift
Task.detached {
    let result = await historyStore.add(
        url: url,
        title: title
    )

    await MainActor.run {
        // Update SwiftUI state
    }
}
```

The C bridge should return quickly. Do not make Swift wait synchronously for database or filesystem operations.

## Data ownership

Use this division of responsibility:

| Component | Responsibility |
|---|---|
| Swift | Windows, native tabs, SwiftUI state, menus, toolbar, user interaction |
| `WKWebView` | Web content, cookies, cache, page navigation, JavaScript |
| Nim | History, bookmarks, settings, sessions, download metadata, filtering rules |
| macOS | Window tabbing, keychain, file panels, permissions, application storage |

`WKWebView` should remain owned by its individual `BrowserWindowController`. Nim should not directly access or control a web view.

A tab should be represented across layers with one shared identifier:

```text
Swift tab ID: UUID
Nim tab/session ID: string or 128-bit identifier
```

The ID allows the app to associate:

- A native window
- A `WKWebView`
- A browser tab model
- Session-restoration data
- Download ownership
- History events

## Nim API categories

Create a narrow API instead of exposing the entire backend.

### History

```c
void history_add(
    const char *url,
    const char *title,
    int64_t visited_at
);

char *history_search(
    const char *query,
    int32_t limit
);

void history_delete(
    const char *url
);
```

### Bookmarks

```c
char *bookmark_create(
    const char *title,
    const char *url,
    const char *folder_id
);

void bookmark_delete(
    const char *bookmark_id
);
```

### Sessions

```c
char *session_save(
    const char *session_json
);

char *session_load(void);
```

### Configuration

```c
char *settings_get(
    const char *key
);

void settings_set(
    const char *key,
    const char *value
);
```

Prefer JSON or another clearly defined serialized format for larger results. This keeps the Swift–Nim boundary stable as the data models evolve.

## Memory management

If Nim returns allocated strings to Swift, provide an explicit release function:

```nim
proc browser_free_string(value: cstring) {.exportc, dynlib.} =
  dealloc(value)
```

Swift must release returned memory after copying it into a Swift `String`.

Alternatively, let Swift provide an output buffer or use JSON files/database queries for larger responses. Never leave ownership ambiguous.

Document every C function with:

- Who allocates the value
- Who frees the value
- Whether the call is synchronous
- Whether it is thread-safe
- What errors can occur

## Error handling

Use a consistent error structure across the bridge:

```c
typedef struct {
    int32_t code;
    const char *message;
} BrowserError;
```

Or return serialized results:

```json
{
  "success": false,
  "error": {
    "code": "database_locked",
    "message": "The history database is currently unavailable"
  }
}
```

Swift should translate backend errors into user-facing errors, while Nim should provide technical error codes.

```swift
enum BrowserCoreError: Error {
    case databaseUnavailable
    case invalidURL
    case permissionDenied
    case serializationFailed
    case unknown(String)
}
```

## Updated implementation phases

### Phase 1: Swift browser shell

Build:

- SwiftUI/AppKit application
- `NSWindow` browser windows
- Native window tabs
- One `WKWebView` per tab
- Address field
- Back, forward, and reload
- Basic `WKNavigationDelegate`

At this stage, use temporary Swift-only history and settings.

### Phase 2: Nim library integration

Add:

- Nim static library
- C-compatible header
- Xcode build phase
- Swift bridging layer
- Versioned C API
- Basic error handling
- Memory-management rules

Start with one function, such as:

```text
history_add(url, title, timestamp)
```

Do not implement the entire backend before testing the bridge.

### Phase 3: Move browser essentials into Nim

Transfer:

- History
- Bookmarks
- Session restoration
- Search-engine settings
- Download metadata
- Permission records

Keep UI models in Swift and backend persistence in Nim.

### Phase 4: Web compatibility

Implement in Swift and `WKWebView`:

- Pop-up handling
- `target="_blank"`
- JavaScript dialogs
- File uploads
- Authentication challenges
- Downloads
- Permission prompts
- Web navigation policies

Nim should store the resulting metadata but should not replace `WKWebView`’s web-rendering responsibilities.

### Phase 5: Reliability and isolation

Add:

- Database migrations
- Corruption recovery
- Crash-safe session writes
- Backend logging
- Bridge tests
- Swift/Nim integration tests
- Optional XPC migration
- Private browsing support
- Data cleanup tools

The first complete milestone should be:

```text
SwiftUI/AppKit
    └── Native tabbed browser windows
            └── One WKWebView per tab
                    └── Nim-backed history and settings
```

This keeps the UI and native window behavior in Swift, uses `WKWebView` for the parts WebKit already provides, and gives Nim responsibility for persistent browser essentials without creating unnecessary coupling between Nim and AppKit.