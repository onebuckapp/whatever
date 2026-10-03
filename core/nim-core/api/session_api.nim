# session_api — session snapshots C ABI.
#
# A snapshot is the whole browser session: every window with its frame, its
# ordered tabs, each tab's URL, title, pinned and privacy flags, its own
# back/forward URL list and index, the selected tab, and the split layout with
# its divider ratio.
#
# It is stored as one JSON document in the `sessions` table rather than through
# the `windows` and `tabs` tables that schema.nim also defines. Those tables
# exist for querying a session rather than replaying it (finding every tab
# pointing at a URL, for instance); a snapshot is always read and written whole,
# and a single row is atomic in a way a multi-table rewrite is not. RESTRICT
# foreign keys would also force a children-first delete order on every save.
#
# Private tabs are never included: Swift filters them out before serializing.
#
# Ownership, threading and sync: see api/abi.nim.

import std/[options, tables]
import openparser/json
import boogie/stores/rdbms
import ../storage/database
import ../storage/schema
import ./abi
import ./settings_api

# `RowData` is a `tables.OrderedTable`, but openparser's JSON exports its own
# `[]`, so column reads go through `tables.[]` explicitly.

const
  ## Key of the single snapshot row.
  SessionKey = "current"

  ## A snapshot larger than this is rejected rather than stored. The payload is
  ## a few hundred bytes per tab, so the cap is generous for a real session and
  ## still bounds a malformed write.
  MaxSnapshotBytes = 8 * 1024 * 1024

proc sessionDocument(db: var Database): string =
  ## The stored snapshot. A fresh install has none, and reports an empty object
  ## rather than an empty string so the payload is always parseable JSON.
  let table = db.sessions.getTable(SessionsTable).get()
  for row in table.where("key", newTextValue(SessionKey)):
    let value = tables.`[]`(row[1], "document")
    if value.kind == dtText:
      return value.strVal
    break
  "{}"

proc sessionLoad*(buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_session_load".} =
  ## The stored snapshot, NUL-terminated, through the two-phase buffer
  ## protocol. A fresh install has no snapshot and reports `Ok` with `{}`.
  var db = storeRef()
  let payload = sessionDocument(db)
  writeBuffer(payload, buffer, capacity, needed)

proc sessionSave*(document: cstring): int32 {.exportc: "bc_session_save".} =
  ## Replaces the stored snapshot. The document must be a JSON object.
  ##
  ## The whole snapshot is one row, so a save is a delete of the previous row
  ## plus an insert: there is no window in which a half-written session could
  ## be read back.
  if document.isNil:
    setError("session document is required")
    return ErrBadInput
  let payload = $document
  if payload.len > MaxSnapshotBytes:
    setError("session snapshot is too large: " & $payload.len & " bytes")
    return ErrBadInput
  let parsed = parseJson(payload)
  if parsed.kind != JObject:
    setError("session document must be a JSON object")
    return ErrBadInput

  var db = storeRef()
  catchingStore("save session"):
    let table = db.sessions.getTable(SessionsTable).get()
    var doomed: seq[string] = @[]
    for row in table.where("key", newTextValue(SessionKey)):
      doomed.add(row[0])
    for pk in doomed:
      discard db.sessions.deleteRow(SessionsTable, pk)
    ## An explicit array rather than `row("k" -> v)`: openparser's JSON exports
    ## `to`, which takes precedence over the `->` conversion `row` expects.
    ## Explicit primary key: this table is `pkmManual`, and the row-shape
    ## overload of `insertRow` only exists for serial tables.
    db.sessions.insertRow(SessionsTable, SessionKey, rdbms.row([
      ("document", newTextValue(payload)),
      ("savedAt", newIntValue(0'i64)),
    ]))
    Ok

proc sessionClear*(): int32 {.exportc: "bc_session_clear".} =
  ## Forgets the stored snapshot, so the next launch opens a fresh session
  ## rather than restoring one.
  var db = storeRef()
  catchingStore("clear session"):
    let table = db.sessions.getTable(SessionsTable).get()
    var doomed: seq[string] = @[]
    for row in table.where("key", newTextValue(SessionKey)):
      doomed.add(row[0])
    for pk in doomed:
      discard db.sessions.deleteRow(SessionsTable, pk)
    Ok