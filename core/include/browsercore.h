/*
 * browsercore — C ABI for the Whatever Nim backend.
 *
 * Hand maintained: Nim 2.2 has no header emitter, so `make check-abi`
 * compares the declarations below against the symbols in
 * `libbrowsercore.a` and fails when they drift apart.
 *
 * Contract for every function here:
 *   * Synchronous. Returns before the caller continues.
 *   * Thread affinity: the exports share module-level state (the error string
 *     and the store handles), so one caller thread at a time. Inside the XPC
 *     service that means one queue; the stores themselves are opened
 *     concurrent, so they are not the bottleneck.
 *   * Nim writes into memory the caller owns. Nothing returned by the core is
 *     heap allocated, so the caller never has to free core memory.
 *   * Variable-length results use a two-phase protocol: call with a NULL
 *     buffer to learn the required size, then again with an exactly sized one.
 *   * Fallible calls return a BC_* status ordinal; bc_last_error carries the
 *     message.
 *
 * Only the XPC service links this library. The app process talks to it over
 * XPC, which is why no call here is on the app's main thread.
 */

#ifndef BROWSERCORE_H
#define BROWSERCORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Side length of the largest Model 2 symbol (version 40). */
#define BC_QR_MAX_SIDE 177

/* Modules in that symbol: BC_QR_MAX_SIDE * BC_QR_MAX_SIDE. Output buffers
 * passed to bc_qr_encode must be at least this many bytes. */
#define BC_QR_MAX_MODULES 31329

/* Status codes shared by the store surface. */
enum {
    BC_OK = 0,
    BC_ERR_BAD_INPUT = 1,      /* a required argument was missing or malformed */
    BC_ERR_BUFFER_TOO_SMALL = 2, /* size query, or an undersized buffer */
    BC_ERR_STORAGE = 3,        /* the store raised; see bc_last_error */
    BC_ERR_ENCODER = 4,        /* QR encoder refused to produce a symbol */
    BC_ERR_NOT_FOUND = 5,      /* no such row or key */
    BC_ERR_LOCKED = 6          /* another process holds the store's lock */
};

/* Registers the calling thread with Nim's runtime and forces module
 * initialization. Idempotent. The XPC service calls it once at launch, before
 * the listener exists, which covers the main thread. */
void bc_init(void);

/* Registers the calling thread with Nim's runtime if it is not already.
 *
 * Nim keeps its allocator's per-thread state in thread-local storage that only a
 * registered thread has. An export reached from an unregistered thread does not
 * return an error: it faults inside the allocator (EXC_BAD_ACCESS at a small
 * offset from nil) and takes the process down.
 *
 * A GCD queue does not promise to run every block on the same thread, so a
 * caller cannot register the thread it started on and assume the rest. Call this
 * before the first core call on any other thread. After the first call on a
 * thread it is only a thread-local read, so it is cheap enough to leave in. */
void bc_register_thread(void);

/* Flushes and closes the stores, releasing boogie's lock on the store path.
 * Idempotent, and a no-op if nothing has been opened. Exports remain callable
 * afterwards: the next one reopens the stores.
 *
 * The core is built with boogie's crash handlers off, which also removes its
 * SIGTERM flush-and-terminate, so nothing else in the process will flush on the
 * way out. A caller should invoke this once it knows no further calls are
 * coming; the service does it when the app's connection goes away, which is
 * what launchd's idle eviction follows. No hook can cover a SIGKILL. */
void bc_shutdown(void);

/* Version of the core as a static NUL-terminated string. Never NULL. */
const char *bc_version(void);

/* Copies the last error message into the caller-owned `buffer` as a
 * NUL-terminated UTF-8 string, truncating when it does not fit. Returns the
 * full message length in bytes so callers can detect truncation. Passing NULL
 * for `buffer` only queries the length. */
int32_t bc_last_error(char *buffer, int32_t capacity);

/* ---------------------------------------------------------------- settings */

/* Settings are one JSON object under a single key, so a schema bump is one
 * version check rather than a sweep over per-key migrations. Swift owns the
 * document's shape; the core only stores and returns it. */

/* Copies the settings document, NUL-terminated, into the caller-owned
 * `buffer`, reporting its full length through `needed` (which may be NULL).
 * Two-phase: pass NULL for `buffer` to query the size, then call again with an
 * exactly sized buffer. A store with nothing saved reports BC_OK with `{}`,
 * so the payload is always parseable JSON. */
int32_t bc_settings_get(char *buffer, int32_t capacity, int32_t *needed);

/* Replaces the stored settings document. `document` must be a JSON object;
 * anything else is refused with BC_ERR_BAD_INPUT. `written` receives the byte
 * length stored, or 0 when the input was rejected; it may be NULL. */
int32_t bc_settings_set(const char *document, int32_t *written);

/* Removes the stored document, returning the store to a fresh-install state. */
int32_t bc_settings_delete(void);

/* Schema version recorded in the store, or 0 when it has never been written. */
int32_t bc_stored_schema_version(void);

/* Schema version this build of the core expects. Never touches the store, so
 * it is safe to call before the first open. */
int32_t bc_core_schema_version(void);

/* --------------------------------------------------------------- bookmarks */

/* Bookmarks are one JSON document per bookmark, keyed by a caller-supplied
 * stable string id. Every listing follows the same two-phase buffer protocol
 * as bc_settings_get. */

/* Every bookmark as a JSON array, in insertion order. */
int32_t bc_bookmark_list(char *buffer, int32_t capacity, int32_t *needed);

/* One bookmark by id. BC_ERR_NOT_FOUND when there is no such key. */
int32_t bc_bookmark_get(const char *id, char *buffer, int32_t capacity,
                        int32_t *needed);

/* Creates or replaces one bookmark. `document` must be a JSON object. */
int32_t bc_bookmark_set(const char *id, const char *document);

/* Deletes one bookmark. BC_ERR_NOT_FOUND when there was no such key. */
int32_t bc_bookmark_delete(const char *id);

/* Removes every bookmark. */
int32_t bc_bookmarks_clear(void);

/* ----------------------------------------------------------------- history */

/* One row per visited page. A revisit of the same URL within a short window
 * updates that row instead of appending a near-duplicate, so a page opened in
 * several tabs seconds apart reads as one visit.
 *
 * Entries carry: id (string primary key), url, title, host, firstVisited and
 * lastVisited (Unix seconds), visitCount (integer).
 *
 * Listing and search return a JSON array of those objects. */

/* Records a visit to `url`.
 *
 * When the same URL was already visited within `collapse_window_secs` the
 * existing row is updated instead of a near-duplicate being added, so a page
 * opened in several tabs seconds apart reads as one visit with a higher
 * `visitCount`. A negative window selects the default of 10 seconds; zero
 * disables collapsing, making every visit its own row.
 *
 * `visited_at` is Unix seconds; a value of 0 or less means "now". */
int32_t bc_history_record(const char *url, const char *title, int64_t visited_at,
                          int64_t collapse_window_secs);

/* Most recently visited entries, newest first. `limit` is clamped to 500. */
int32_t bc_history_recent(int32_t limit, char *buffer, int32_t capacity,
                          int32_t *needed);

/* Entries for one `YYYY-MM-DD` local-time bucket, newest first. An indexed
 * equality query rather than a scan. */
int32_t bc_history_by_day(const char *day, char *buffer, int32_t capacity,
                          int32_t *needed);

/* Fuzzy history search, best match first.
 *
 * Every character of `query` must appear in a row, in order but not necessarily
 * contiguously. Ranking comes from openparser/fuzzy — consecutive runs,
 * word-boundary hits and gap penalties — so it reflects how well the row matches
 * what was typed rather than how recently it was visited. Matching is
 * case-insensitive.
 *
 * Each row is scored as its title and URL joined, and the reported positions are
 * split back onto those two fields, so one row is one result however many fields
 * matched. `positions` are BYTE offsets into that field, not character indices:
 * a title with any non-ASCII text in it will need converting before use with
 * NSRange or String.Index. Offsets landing on the separator between the two
 * fields are dropped.
 *
 * At most 2000 rows are scored, thinned by halving rather than truncated, so
 * the sample spans the whole history instead of only its oldest rows. `limit` is
 * clamped to 500. An empty query returns an empty array, not an error. */
int32_t bc_history_fuzzy_search(const char *query, int32_t limit, char *buffer,
                                int32_t capacity, int32_t *needed);

/* Deletes one entry by primary key. BC_ERR_NOT_FOUND when no such row. */
int32_t bc_history_delete(const char *id);

/* Deletes every entry last visited before `cutoff` (Unix seconds), reporting
 * how many rows went through `removed` (which may be NULL). */
int32_t bc_history_delete_before(int64_t cutoff, int32_t *removed);

/* Removes all history, keeping the table so the next insert needs no schema
 * work. */
int32_t bc_history_clear(void);

/* --------------------------------------------------------------------- find */

/* Find-in-page matching: every occurrence of `query` in `text`, front to
 * back, as half-open BYTE ranges.
 *
 * `text` is the page's visible text exactly as the app extracted it from the
 * live DOM, and matching is exact-substring search compiled to an
 * openparser/regex pattern — the query's metacharacters are escaped, so what
 * was typed is what the page must contain. Deliberately not fuzzy matching:
 * subsequence hits would highlight scattered fragments instead of the
 * contiguous occurrences next/previous stepping needs.
 *
 * `match_case` and `whole_words` are zero for off, nonzero for on. Without
 * match case, ASCII letters fold (`H` matches `h`); Latin diacritics fold to
 * ASCII on both sides first (`șase` meets `sase` whichever side was typed
 * with the diacritic). Anything else matches exactly. Whole words wrap the
 * literal in `\b(?:...)\b`.
 *
 * Returns `{"matches":[{"start":s,"stop":e}], "total":n, "hasMore":b,
 * "truncated":b}`. `total` counts every match; `limit` (non-positive means
 * the 2000 maximum) caps the returned list and `hasMore` says it was cut.
 * Text over 1 MiB is scanned only up to the cap and `truncated` comes back
 * true; the kept offsets stay valid because the cut is a prefix. `start` and
 * `stop` are BYTE offsets into `text`, not character indices: non-ASCII
 * needs converting to UTF-16 before touching the DOM. An empty query
 * returns an empty list, not an error. */
int32_t bc_find_matches(const char *text, const char *query, int32_t match_case,
                        int32_t whole_words, int32_t limit, char *buffer,
                        int32_t capacity, int32_t *needed);

/* ---------------------------------------------------------------- sessions */

/* The session snapshot: every window with its frame, ordered tabs, per-tab URL
 * and title, the per-tab back/forward URL list and index, the selected tab, and
 * the split layout with its divider ratio. Private tabs are the caller's to
 * exclude; the core stores what it is given.
 *
 * Stored as one JSON document so a save is a single atomic row replacement. */

/* The stored snapshot through the two-phase buffer protocol. Nothing saved
 * reports BC_OK with `{}`. */
int32_t bc_session_load(char *buffer, int32_t capacity, int32_t *needed);

/* Replaces the stored snapshot. `document` must be a JSON object. */
int32_t bc_session_save(const char *document);

/* Forgets the stored snapshot, so the next launch opens a fresh session. */
int32_t bc_session_clear(void);

/* ------------------------------------------------------------------- feeds */

/* Feed subscriptions and cached articles in a separate `feeds` store.
 *
 * Networking stays outside these calls: the app downloads page, feed,
 * favicon, and thumbnail bytes, and the core parses, normalizes, and persists
 * them. Payload strings must not contain NUL bytes, because they cross as C
 * strings and the two-phase protocol relies on a single terminator.
 *
 * Images are Base64 text because the store has text rather than binary
 * columns. MIME, dimensions, source, and size limits are checked before bytes
 * are persisted. Listings omit bodies and image bytes; dedicated article and
 * media calls return the heavy fields for the rows actually on screen. */

/* Records a subscription without fetching anything. `site_name` may be NULL
 * or empty, in which case the page host is used until a feed title arrives. */
int32_t bc_feed_subscribe(const char *feed_url, const char *page_url,
                          const char *site_name, const char *declared_title,
                          const char *declared_type, int64_t subscribed_at);

/* Removes a subscription and its cached articles, children first. */
int32_t bc_feed_unsubscribe(const char *feed_url);

/* Every subscription as a JSON array, newest first, with article and unread
 * counts. */
int32_t bc_feed_subscriptions(char *buffer, int32_t capacity, int32_t *needed);

/* Parses one downloaded feed document and replaces the subscription's cached
 * articles with the normalized result.
 *
 * The NULL-buffer size query parses but does not persist; the exactly sized
 * call persists. `fetched_at` of 0 or less means "now". BC_ERR_NOT_FOUND when
 * the feed was never subscribed. */
int32_t bc_feed_ingest(const char *feed_url, int64_t fetched_at,
                       const char *payload, char *buffer, int32_t capacity,
                       int32_t *needed);

/* Strict variant of `bc_feed_ingest`. Nothing is recovered: malformed feeds,
 * missing required metadata, and RDF/RSS 1.0 documents are recorded as parse
 * errors and refused. */
int32_t bc_feed_ingest_strict(const char *feed_url, int64_t fetched_at,
                              const char *payload, char *buffer,
                              int32_t capacity, int32_t *needed);

/* Retains the newest `maximum_articles` rows for one subscription and deletes
 * the rest. `maximum_articles` is between 1 and 5000. */
int32_t bc_feed_prune(const char *feed_url, int32_t maximum_articles);

/* Records a fetch outcome that carried no parseable replacement, such as a
 * conditional 304 or a transport failure. `status` is one of "ok",
 * "not-modified", "transport-error", "http-error", or "parse-error". */
int32_t bc_feed_note_fetch(const char *feed_url, int64_t checked_at,
                           const char *status, const char *error,
                           const char *etag, const char *last_modified);

/* Article summaries, newest first. An empty `feed_url` lists every
 * subscription. Pagination uses the sort key rather than an offset:
 * `before_published_at` greater than zero selects older rows, and `before_id`
 * breaks ties within the same timestamp. */
int32_t bc_feed_articles(const char *feed_url, int32_t only_unread,
                         int32_t limit, int64_t before_published_at,
                         int64_t before_id, char *buffer, int32_t capacity,
                         int32_t *needed);

/* One article, including bodies and any persisted thumbnail bytes. */
int32_t bc_feed_article(int64_t article_id, char *buffer, int32_t capacity,
                        int32_t *needed);

/* Sets read/saved display state. Each flag is 0 or 1. */
int32_t bc_feed_set_article_state(int64_t article_id, int32_t is_read,
                                  int32_t is_saved);

/* Stores validated thumbnail bytes for one article. */
int32_t bc_feed_attach_thumbnail(int64_t article_id, const char *mime,
                                 int64_t width, int64_t height,
                                 const char *image_base64);

/* One article's persisted thumbnail metadata and bytes. BC_ERR_NOT_FOUND when
 * the article or its bytes are absent. */
int32_t bc_feed_thumbnail(int64_t article_id, char *buffer, int32_t capacity,
                          int32_t *needed);

/* Stores validated favicon bytes for one subscription. */
int32_t bc_feed_attach_favicon(const char *feed_url, const char *remote_url,
                               const char *mime, const char *image_base64);

/* One subscription's persisted favicon metadata and bytes. BC_ERR_NOT_FOUND
 * when the subscription or its bytes are absent. */
int32_t bc_feed_favicon(const char *feed_url, char *buffer, int32_t capacity,
                        int32_t *needed);

/* Candidate feeds declared by explicitly supplied page source. The live
 * browser path should prefer the rendered DOM; this is for manual and
 * recovery flows where downloading the page again is explicit. */
int32_t bc_feed_discover_from_html(const char *page_url, const char *html,
                                   char *buffer, int32_t capacity,
                                   int32_t *needed);

/* ---------------------------------------------------------------------- QR */

/* Error correction levels accepted by bc_qr_encode. */
enum {
    BC_QR_EC_LOW = 0,
    BC_QR_EC_MEDIUM = 1,
    BC_QR_EC_QUARTILE = 2,
    BC_QR_EC_HIGH = 3
};

/* Encodes UTF-8 `text` as a Model 2 QR symbol.
 *
 * Writes one byte per module into `out_modules`, row-major from the
 * top-left corner: 1 for a dark module, 0 for a light one. `capacity` is
 * the byte length of that buffer and must be at least BC_QR_MAX_MODULES;
 * when it is smaller nothing is written and BC_ERR_BUFFER_TOO_SMALL is
 * returned. The symbol side length is reported through `out_width` and
 * `out_height`, either of which may be NULL.
 *
 * `ec_level` is one of the BC_QR_EC_* values; anything else is treated as
 * BC_QR_EC_MEDIUM.
 *
 * Returns one of the BC_* result codes. */
int32_t bc_qr_encode(const char *text, int32_t ec_level, uint8_t *out_modules,
                     int32_t capacity, int32_t *out_width, int32_t *out_height);

/* Encodes UTF-8 `text` as a Model 2 QR symbol and renders it as a
 * standalone SVG document using openparser's SVG renderer.
 *
 * `scale` is the pixel size of one module (at least 1) and `border` the
 * quiet zone in modules (at least 0). `dark` / `light` are CSS colors for
 * dark and light modules; NULL or empty selects the defaults (`#000000`
 * and `none`, i.e. a transparent background).
 *
 * The document is written NUL-terminated into the caller-owned `out_svg`
 * buffer and its full byte length including the terminator is reported
 * through `out_needed`, which may be NULL. Pass NULL for `out_svg` (or a
 * buffer that is too small) to query the required size: nothing is written
 * and BC_ERR_BUFFER_TOO_SMALL is returned.
 *
 * Returns one of the BC_* result codes. */
int32_t bc_qr_svg(const char *text, int32_t ec_level, int32_t scale,
                  int32_t border, const char *dark, const char *light,
                  char *out_svg, int32_t capacity, int32_t *out_needed);

/* ----------------------------------------------------------------- filter */

/* Hosts text and user rules in, WebKit content-blocker JSON out.
 *
 * Each line of `lists` is one entry: `0.0.0.0 host`, `127.0.0.1 host`, a
 * bare `host`, `||domain^...` network rules, `@@||domain^` / `@@domain`
 * exceptions, or `##selector` / `domain##selector` cosmetic rules. `#`
 * comments, `!` comments, `[Adblock Plus]` headers, blank lines and
 * malformed entries are skipped, never fatal.
 *
 * Host rules anchor the hostname boundary, so a rule for `ads.example.com`
 * never matches `not-ads.example.com.evil.test`. Exceptions are appended
 * after the rules they cancel. An empty string compiles to `[]`, a valid
 * empty rule list; NULL `lists` is refused with BC_ERR_BAD_INPUT.
 *
 * The JSON array is written NUL-terminated into the caller-owned `buffer`
 * through the two-phase protocol (`needed`, which may be NULL, reports the
 * full length including the terminator). Returns one of the BC_* codes. */
int32_t bc_filter_compile(const char *lists, char *buffer, int32_t capacity,
                          int32_t *needed);

/* Counts and change-detection fingerprint for the same input
 * `bc_filter_compile` takes, without building the rule JSON: rule, block,
 * cosmetic and exception counts, skipped lines, the FNV-1a input hash as
 * lowercase hex (change detection only, not a security hash), and the
 * echoed source version. Same NULL contract and two-phase protocol. */
int32_t bc_filter_meta(const char *lists, const char *version, char *buffer,
                       int32_t capacity, int32_t *needed);

/* -------------------------------------------------------------- downloads */

/* Download history: one row per finished or in-flight browser download.
 * Bytes never cross into the store, only paths and counts.
 *
 * Rows are keyed by a client-generated id (a UUID from the app), so
 * recording needs no id-return round trip and progress updates reference a
 * stable handle from the download's first byte. */

/* Starts tracking a download. `bytes_expected` is -1 while the size is
 * unknown; `started_at` of 0 or less means "now". Recording an existing id
 * restarts it under a fresh row. */
int32_t bc_download_record(const char *id, const char *source_url,
                           const char *filename,
                           const char *destination_path,
                           int64_t bytes_expected, int64_t started_at);

/* Advances the byte count of an in-flight download. Terminal rows ignore
 * late progress. BC_ERR_NOT_FOUND when the id was never recorded. */
int32_t bc_download_progress(const char *id, int64_t bytes_received);

/* Marks a download done. A negative byte count keeps whatever progress
 * recorded last, for delegates that only report completion. */
int32_t bc_download_finish(const char *id, int64_t bytes_received,
                           int64_t finished_at);

/* Marks a download failed with the delegate's message. */
int32_t bc_download_fail(const char *id, const char *error,
                         int64_t bytes_received, int64_t finished_at);

/* Marks a download cancelled by the user. */
int32_t bc_download_cancel(const char *id, int64_t finished_at);

/* Download history, newest first, capped. */
int32_t bc_download_list(char *buffer, int32_t capacity, int32_t *needed);

/* Forgets one history row. The file itself is untouched. BC_ERR_NOT_FOUND
 * when the id was never recorded. */
int32_t bc_download_remove(const char *id);

/* Forgets all download history. Files on disk are untouched. */
int32_t bc_download_clear(void);

#ifdef __cplusplus
}
#endif

#endif /* BROWSERCORE_H */