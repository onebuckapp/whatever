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

#ifdef __cplusplus
}
#endif

#endif /* BROWSERCORE_H */