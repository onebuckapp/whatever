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

import std/[options, sets, strutils, tables]
import openparser/json
import boogie/stores/kv
import ../storage/database
import ../storage/schema
import ./abi
import ./profile_api

var
  ## One open database per profile id. The active profile (see
  ## api/profile_api.nim) selects the entry; two windows on different
  ## profiles hold two open databases on the same core thread, each with
  ## its own file locks on its own directory.
  stores: Table[string, Database]
  ## Ids with a live entry in `stores`. `storeRef` inserts a zero
  ## placeholder on failure paths (see below), so "has an entry" and
  ## "is open" are deliberately not the same predicate.
  openedIds: HashSet[string]
  ## Returned by `storeRef` when no profile can be resolved. Callers fail
  ## inside their `catchingStore` on it, exactly as they did on an
  ## unopened store before profiles existed.
  fallbackDb = Database()

proc ensureOpen(): int32 =
  ## Opens the active profile's stores on first use. A path already locked
  ## by another process surfaces as `ErrLocked` rather than blocking on the
  ## file lock, so a second service instance reports the problem instead of
  ## hanging.
  ##
  ## With no bound profile, resolves the most recently used one — the
  ## unbound fallback that keeps single-profile callers working. Bound
  ## callers (every XPC job) always select explicitly first.
  var id = activeProfileId()
  if id.len == 0:
    id = resolveDefaultProfile()
    if id.len == 0:
      setError("no browser profile is available")
      return ErrStorage
    setActiveProfile(id)
  if id in openedIds:
    return Ok
  let status = catchingStore("open store"):
    var db = openDatabase(profileDir(id))
    db.applySchema()
    db.settings.put(SchemaVersionKey, $SchemaVersion)
    stores[id] = db
    openedIds.incl(id)
    Ok
  status

proc storeRef*(): var Database =
  ## Live handle for the other API modules: the active profile's database.
  ## Opens the stores on demand.
  ##
  ## Never raises: on failure paths (no resolvable profile, open failure)
  ## the caller gets a zero placeholder, which fails inside its
  ## `catchingStore` exactly as an unopened store did before profiles
  ## existed. A single call expression because Nim only accepts calls (not
  ## branches) as `var` results; the placeholder means `closeProfileStores`
  ## and `shutdownStores` consult `openedIds`, never the table, before
  ## touching handles.
  discard ensureOpen()
  mgetOrPut(stores, activeProfileId(), fallbackDb)

proc closeProfileStores*(id: string) =
  ## Flushes and closes one profile's stores, forgetting its handles so a
  ## later call reopens them. The profile-delete path calls this before
  ## removing the directory; closing first releases the file locks.
  ##
  ## Through a local: handles are shared references inside the `Database`
  ## value (every `var db = storeRef()` copy already relies on that), so
  ## closing the copy closes the profile's stores.
  if id in openedIds:
    var db = stores[id]
    db.shutdown()
    stores.del(id)
    openedIds.excl(id)

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
  var db = storeRef()
  let document = db.settings.get(SettingsDocKey)
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
  var db = storeRef()
  let status = catchingStore("write settings"):
    db.settings.put(SettingsDocKey, payload)
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
  var db = storeRef()
  catchingStore("delete settings"):
    discard db.settings.delete(SettingsDocKey)
    Ok

proc storedSchemaVersion*(): int32 {.exportc: "bc_stored_schema_version".} =
  ## Schema version recorded in the store, or 0 when the store has never been
  ## written. Swift compares this against the version it last wrote; a mismatch
  ## means the stored document predates a shape change and needs migrating.
  if ensureOpen() != Ok:
    return -ErrStorage
  var db = storeRef()
  let stored = db.settings.get(SchemaVersionKey)
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

proc shutdownStores*() =
  ## Flushes and closes every open profile's stores, then marks them
  ## closed so later calls reopen them.
  ##
  ## The core is built with boogie's crash handlers off, which also removes its
  ## SIGTERM flush-and-exit. Without this, launchd's SIGKILL of an idle XPC
  ## service, or logout, would drop whatever is still in the WAL. The service
  ## process registers this at exit, and `bc_shutdown` exposes it for a caller
  ## that wants to release the store earlier.
  for id in openedIds:
    var db = stores[id]
    db.shutdown()
  stores.clear()
  openedIds.clear()