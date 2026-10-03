/*
 * browsercore — C ABI for the Whatever Nim backend.
 *
 * Hand maintained: Nim 2.2 has no header emitter, so `make check-abi`
 * compares the declarations below against the symbols in
 * `libbrowsercore.a` and fails when they drift apart.
 *
 * Contract for every function here:
 *   * Synchronous. Returns before Swift continues.
 *   * Nim writes into memory Swift owns. Nothing returned by the core is
 *     heap allocated, so Swift never has to free core memory.
 *   * Main thread only. The exports share module-level state, so they are
 *     neither re-entrant nor thread-safe. Every call is microseconds for
 *     web-sized payloads, so no asynchronous variant is needed.
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

/* Registers the calling thread with Nim's runtime and forces module
 * initialization. Idempotent, but Swift calls it once at launch. */
void bc_init(void);

/* Version of the core as a static NUL-terminated string. Never NULL. */
const char *bc_version(void);

/* Error correction levels accepted by bc_qr_encode. */
enum {
    BC_QR_EC_LOW = 0,
    BC_QR_EC_MEDIUM = 1,
    BC_QR_EC_QUARTILE = 2,
    BC_QR_EC_HIGH = 3
};

/* Result codes returned by bc_qr_encode. */
enum {
    BC_OK = 0,
    BC_ERR_BAD_INPUT = 1,      /* empty or missing payload */
    BC_ERR_TOO_LONG = 2,       /* payload exceeds the requested version range */
    BC_ERR_BUFFER_TOO_SMALL = 3, /* out_modules is under BC_QR_MAX_MODULES */
    BC_ERR_ENCODER = 4         /* encoder refused to produce a symbol */
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

/* Copies the last error message into the caller-owned `buffer` as a
 * NUL-terminated UTF-8 string, truncating when it does not fit. Returns the
 * full message length in bytes so callers can detect truncation. Passing
 * NULL for `buffer` only queries the length. */
int32_t bc_last_error(char *buffer, int32_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* BROWSERCORE_H */