# Whatever Browser – Made by Humans from OpenPeeps
#
#     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# settings_api — app settings C ABI.
#
# Settings are a single JSON document under one kv key rather than a key per
# setting. The Swift side owns the shape; this layer only moves bytes and
# carries the schema version so an upgrade can tell an old document from a new
# one.
#
# Ownership, threading and sync: see api/abi.nim.

import std/[options, strutils]
import openparser/json
import boogie/stores/kv
import ../storage/database
import ../storage/schema
import ./abi

var
  stores = Database()
  opened = false

proc ensureOpen(): int32 =
  ## Opens the stores on first use. A path already locked by another process
  ## surfaces as `ErrLocked` rather than blocking on the file lock, so a second
  ## service instance reports the problem instead of hanging.
  if opened:
    return Ok
  let status = catchingStore("open store"):
    stores = openDatabase()
    stores.applySchema()
    opened = true
    Ok
  if status != Ok:
    return status
  stores.settings.put(SchemaVersionKey, $SchemaVersion)
  Ok

proc settingsGet*(buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_settings_get".} =
  ## Copies the settings document, NUL-terminated, into the caller-owned
  ## buffer and reports its full length through `needed`, which may be NULL.
  ##
  ## Two-phase: pass NULL for `buffer` to query the required size, then call
  ## again with an exactly sized buffer. A fresh install has no document and
  ## gets `{}`, which still reports `Ok`; Swift distinguishes "nothing saved"
  ## from "could not read" by the status, not by the payload.
  ## Propagates the open failure verbatim: a held lock (`ErrLocked`) is a
  ## different problem for the caller than a corrupt or unwritable store.
  let openStatus = ensureOpen()
  if openStatus != Ok:
    return openStatus
  let document = stores.settings.get(SettingsDocKey)
  ## A fresh install reports an empty object rather than an empty string, so
  ## the payload is always parseable JSON and Swift never has to special-case
  ## "nothing saved yet" before decoding.
  let payload = if document.isSome: document.get else: "{}"
  writeBuffer(payload, buffer, capacity, needed)

proc settingsSet*(document: cstring, written: ptr int32): int32 {.exportc: "bc_settings_set".} =
  ## Replaces the stored settings document. `written` receives the document's
  ## byte length, or 0 when the input was rejected.
  ## Propagates the open failure verbatim: a held lock (`ErrLocked`) is a
  ## different problem for the caller than a corrupt or unwritable store.
  let openStatus = ensureOpen()
  if openStatus != Ok:
    return openStatus
  if document.isNil:
    setError("settings document is required")
    return ErrBadInput
  let payload = $document
  ## Reject anything that is not a JSON object: a document that parses as a
  ## string or array would silently lose every field on the Swift side.
  let parsed = parseJson(payload)
  if parsed.kind != JObject:
    setError("settings document must be a JSON object")
    return ErrBadInput
  let status = catchingStore("write settings"):
    stores.settings.put(SettingsDocKey, payload)
    Ok
  if status == Ok and not written.isNil:
    written[] = int32(payload.len)
  status

proc settingsDelete*(): int32 {.exportc: "bc_settings_delete".} =
  ## Removes the stored document, returning the store to its fresh-install
  ## state.
  ## Propagates the open failure verbatim: a held lock (`ErrLocked`) is a
  ## different problem for the caller than a corrupt or unwritable store.
  let openStatus = ensureOpen()
  if openStatus != Ok:
    return openStatus
  catchingStore("delete settings"):
    discard stores.settings.delete(SettingsDocKey)
    Ok

proc storedSchemaVersion*(): int32 {.exportc: "bc_stored_schema_version".} =
  ## Schema version recorded in the store, or 0 when the store has never been
  ## written. Swift compares this against the version it last wrote; a mismatch
  ## means the stored document predates a shape change and needs migrating.
  if ensureOpen() != Ok:
    return -ErrStorage
  let stored = stores.settings.get(SchemaVersionKey)
  if stored.isNone:
    return 0'i32
  try:
    int32(parseInt(stored.get))
  except ValueError:
    0'i32

proc coreSchemaVersion*(): int32 {.exportc: "bc_core_schema_version".} =
  ## Schema version this build of the core expects. Never touches the store, so
  ## it is safe to call before the first open.
  clearError()
  int32(SchemaVersion)


proc storeRef*(): var Database =
  ## Live handle for the other API modules. Opens the stores on demand.
  discard ensureOpen()
  stores

proc shutdownStores*() =
  ## Flushes and closes the stores, then marks them closed so a later call
  ## reopens them.
  ##
  ## The core is built with boogie's crash handlers off, which also removes its
  ## SIGTERM flush-and-exit. Without this, launchd's SIGKILL of an idle XPC
  ## service, or logout, would drop whatever is still in the WAL. The service
  ## process registers this at exit, and `bc_shutdown` exposes it for a caller
  ## that wants to release the store earlier.
  if not opened:
    return
  stores.shutdown()
  opened = false