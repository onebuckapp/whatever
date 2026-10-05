# Feed reader plan — 2026-10-05

## Status

Plan saved locally. Implementation starts with the recommended defaults below.
Any item marked “Confirm” can still override the default during the build.

## MVP outcome

- Detect standard feed-autodiscovery metadata on the selected page.
- Show an RSS button immediately after the search field only when feeds are available.
- Support subscription, fetching, refreshing, and native two-card-per-row reading.
- Persist subscriptions, feed metadata, articles, favicons, and thumbnails in a new Boogie database.
- Render thumbnail, title, description, site name, favicon, and timestamp in each card.

## Confirmed defaults

- Network boundary: Swift `URLSession` downloads page/feed/image bytes; Nim parses, normalizes, and persists them.
- Reader surface: dedicated feed-reader card/panel, not another Settings section.
- Article activation: open a native article-detail view first, with explicit browser-open actions.
- Image and retention defaults: 64 KB favicons, 256 KB downscaled thumbnails, and 200 retained articles per feed.
- Discovery scope: standard `<link rel="alternate">` autodiscovery only for MVP.

## Architecture

- The Swift app performs HTTP and image work.
- The Nim core validates, normalizes, parses, deduplicates, and persists feed data.
- The app never opens Boogie stores directly.
- The `WhateverStore` XPC service remains the only store owner.
- Use `openparser/rss.parseRss` for RSS 2.0.
- Use `openparser/feed.parseAtom` for Atom.
- Use `openparser/html.parseHtml` only for explicitly supplied raw-HTML fallback discovery.
- Do not use Nim `fetchAtom` or `fetchRss` inside the synchronous XPC service.

## Feed discovery

Add `macos/Sources/Browser/Feeds/FeedDiscovery.swift`.

- Evaluate JavaScript in the selected tab’s live `WKWebView` after loading finishes.
- Collect standard declarations:

```html
<link rel="alternate" type="application/rss+xml" href="...">
<link rel="alternate" type="application/atom+xml" href="...">
<link rel="alternate" type="application/rdf+xml" href="...">
```

- Resolve candidates against `document.baseURI`.
- Accept only `http` and `https` URLs.
- Normalize duplicates while preserving candidate order.
- Cache by tab, page URL, and navigation generation.
- Clear stale candidates on tab switches, redirects, replacements, failures, and private contexts.
- Hook discovery into the existing favicon/update flow in `BrowserTabController`.

No network request is performed merely because a feed was discovered.

## Toolbar affordance

- Add a feed button to `BrowserToolbarController`.
- Place it immediately after the search field in a small horizontal center stack.
- Preserve the existing search-field width and toolbar centering.
- Default to hidden.
- Show only when the selected tab exposes feed candidates.
- Match existing toolbar glyph sizing, tooltips, and accessibility behavior.

Behavior:

- One candidate and no subscription: subscribe, then open the reader.
- One candidate and an existing subscription: open that feed.
- Multiple candidates: show a candidate picker.
- No candidates: hide the button.

## Boogie storage

Add a separate `feeds` Boogie relational store at:

```text
~/Library/Application Support/Whatever/feeds
```

Update:

- `core/nim-core/storage/database.nim`
- `core/nim-core/storage/schema.nim`
- Core shutdown handling
- Core tests

Because this is a new store, existing history/session schema migration is not required.

Boogie relational values support text, integers, floats, booleans, JSON, and null, but no native binary column. Consequently:

- Store image bytes as Base64 in `dtText`.
- Store media/favicon metadata separately from image bytes.
- Enforce byte and dimension caps before persistence.
- Store a site favicon once per subscription.
- Avoid inlining large Base64 payloads in article-list responses.
- Provide separate thumbnail/favicon retrieval calls for visible cards.

### `feed_subscriptions`

Manual primary key on normalized feed URL:

- `feedURL`
- `pageURL`
- `siteHost`
- `siteName`
- `feedFormat`
- `feedTitle`
- `declaredTitle`
- `declaredType`
- `faviconRemoteURL`
- `faviconMime`
- `faviconImageBase64`
- `subscribedAt`
- `lastCheckedAt`
- `lastETag`
- `lastModified`
- `lastStatus`
- `lastError`
- `autoRefreshEnabled`

### `feed_articles`

Serial primary key, indexed by `feedURL`:

- `feedURL`
- `guid`
- `canonicalURL`
- `title`
- `authorsJson`
- `publishedAt`
- `updatedAt`
- `publishedRaw`
- `fetchedAt`
- `summaryText`
- `summaryHTML`
- `contentText`
- `contentHTML`
- `thumbnailRemoteURL`
- `thumbnailMime`
- `thumbnailWidth`
- `thumbnailHeight`
- `thumbnailSource`
- `thumbnailImageBase64`
- `siteName`
- `siteHost`
- `isRead`
- `isSaved`

Article identity prefers GUID, then canonical URL plus content hash.

## Core API and transport

Add `core/nim-core/api/feed_api.nim` with synchronous JSON exports:

- `bc_feed_subscribe`
- `bc_feed_unsubscribe`
- `bc_feed_subscriptions`
- `bc_feed_ingest`
- `bc_feed_articles`
- `bc_feed_set_article_state`
- `bc_feed_attach_thumbnail`
- `bc_feed_attach_favicon`
- `bc_feed_discover_from_html`

Update:

- `core/nim-core/browsercore.nim`
- `core/Makefile`
- `core/include/browsercore.h`
- `macos/Shared/WhateverStoreProtocol.swift`
- `macos/Store/StoreService.swift`
- `macos/Sources/Storage/StoreClient.swift`
- `macos/Sources/Core/BrowserCore.swift`
- Core and manual tests

Run `make check-abi` after every ABI/header change.

Use strict parsing first, then a lenient projection for malformed-but-usable feeds.
Record malformed feeds as fetch errors without partial duplicate writes.
Use delete-plus-insert for concurrent-store row replacement.

## Fetching and media

Add `macos/Sources/Browser/Feeds/FeedFetcher.swift`.

- Follow safe redirects.
- Honor stored ETag and Last-Modified values.
- Enforce timeouts and maximum body sizes.
- Validate status codes and content types.
- Fetch only on subscribe, manual refresh, eligible automatic refresh, or explicit user action.

Thumbnail precedence:

1. `media:content` image
2. Image enclosure
3. Open Graph image
4. Twitter image
5. First sufficiently large in-content image

Each persisted image must have:

- Supported MIME and magic bytes
- Minimum usable dimensions
- Downscaled reader-card dimensions
- Remote URL
- Base64 bytes
- Source classification
- Alternative text when supplied

Reuse `FaviconLoader` for site icons and persist one favicon per subscription.

## Reader UI

Add:

- `macos/Sources/Browser/Feeds/FeedReaderStore.swift`
- `macos/Sources/Browser/Feeds/FeedReaderView.swift`
- `macos/Sources/Browser/Feeds/FeedArticleCard.swift`
- `macos/Sources/Browser/Feeds/FeedModels.swift`
- Possibly `macos/Sources/Browser/Feeds/FeedSubscriptionView.swift`

Use a native two-column adaptive grid and collapse to one column when two readable cards cannot fit.

Each card shows:

- Cached thumbnail or favicon/monogram placeholder
- Sixteen-point favicon
- Site name
- Feed/source label
- Timestamp
- Two-line title
- Three-line plain-text description
- Unread indicator
- Save and read controls
- Context actions for opening, copying, marking read/unread, and managing subscriptions
- Complete VoiceOver labels and Dynamic Type behavior

Render plain-text excerpts in MVP, not raw feed HTML. Browser-supplied HTML requires a separate hardened article renderer.

Reader states:

- Loading
- Loaded
- No subscriptions
- Empty feed
- Refreshing
- Failed fetch
- Offline but cached
- Unsupported feed
- Restricted private context

## Privacy, security, and performance

- Do not add feed discovery or fetching to browsing history.
- Do not persist subscriptions, articles, or media from private tabs.
- Avoid logging URLs, bodies, authentication material, GUIDs, or image bytes.
- Redact credentials and feed tokens in UI and diagnostics.
- Allow only `http` and `https` feed/media URLs.
- Sanitize HTML before Swift text rendering.
- Validate and decode images off the main thread.
- Cache decoded thumbnails in memory while retaining persisted bytes in Boogie.
- Apply retention and media limits.
- Reuse existing debounce patterns for refresh and state writes.

## Verification

Core:

- `make test`
- `make check-abi`
- RSS, Atom, malformed, missing-author/date, duplicate GUID/link, relative URL, base-href, multi-candidate, schema-creation, retention, and state fixtures.

App:

- `make macos`
- No-feed, single-feed, multi-feed, relative URL, redirect, unreachable feed, malformed feed, missing thumbnail, oversized media, tab switches, back/forward navigation, private tabs, offline cached reading, and refresh success/failure checks.
