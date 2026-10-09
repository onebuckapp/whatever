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

# download_api — browser download history C ABI.
#
# A separate Boogie `downloads` store holds one row per finished or in-flight
# download. The service owns the store; the app only sees JSON through the
# two-phase buffer protocol.
#
# The app records through this API from its `WKDownload` delegate: a row at
# start, byte counts as they arrive, and a terminal state at finish, failure,
# or cancellation. Bytes themselves never cross into the store — only the
# filesystem paths and counts do, so a large download costs a few small row
# rewrites rather than a second copy of its content.
#
# Ownership, threading and sync: see api/abi.nim.

import std/[algorithm, options, strutils, tables, times]
import openparser/json
import boogie/stores/rdbms
import ../storage/database
import ../storage/schema
import ./abi
import ./settings_api

const
  ## Longest accepted URL, filename, or path. Longer values are rejected
  ## rather than truncated, because truncation creates a different address.
  MaxDownloadTextChars = 2048

  ## Upper bound on one download listing. History is newest-first and the
  ## popup renders what fits; thousands of rows would turn a panel open into
  ## a cleanup operation of its own.
  MaxDownloadResults = 500

type
  DownloadState = enum
    dsInProgress = "in-progress"
    dsDone = "done"
    dsFailed = "failed"
    dsCancelled = "cancelled"

proc requiredText(value: cstring, name: string): string =
  if value.isNil or ($value).strip.len == 0:
    setError(name & " is required")
    return ""
  let text = ($value).strip
  if text.len > MaxDownloadTextChars:
    setError(name & " is too long")
    return ""
  text

proc optionalText(value: cstring): string =
  if value.isNil:
    return ""
  ($value).strip

proc nowSeconds(): int64 =
  int64(epochTime())

proc downloadTables(db: var Database): DbTable =
  db.downloads.getTable(DownloadItemsTable).get()

proc cellText(data: RowData, key: string): string =
  if not tables.hasKey(data, key):
    return ""
  let value = tables.`[]`(data, key)
  if value.kind == dtText: value.strVal else: ""

proc cellInt(data: RowData, key: string): int64 =
  if not tables.hasKey(data, key):
    return 0'i64
  let value = tables.`[]`(data, key)
  if value.kind == dtInt: value.intVal else: 0'i64

proc downloadRow(id, sourceURL, filename, destinationPath: string,
                 bytesExpected, bytesReceived: int64, state: DownloadState,
                 errorText: string, startedAt, finishedAt: int64): RowData =
  rdbms.row([
    ("id", newTextValue(id)),
    ("sourceURL", newTextValue(sourceURL)),
    ("filename", newTextValue(filename)),
    ("destinationPath", newTextValue(destinationPath)),
    ("bytesExpected", newIntValue(bytesExpected)),
    ("bytesReceived", newIntValue(bytesReceived)),
    ("state", newTextValue($state)),
    ("errorText", newTextValue(errorText)),
    ("startedAt", newIntValue(startedAt)),
    ("finishedAt", newIntValue(finishedAt)),
  ])

proc findDownload(table: DbTable, id: string): tuple[found: bool, pk: string, data: RowData] =
  for row in table.where("id", newTextValue(id)):
    return (true, row[0], row[1])
  (false, "", initOrderedTable[string, Value]())

proc replaceRow(db: var Database, pk: string, next: RowData) =
  ## Boogie raises on in-place updates under concurrency, so every mutation is
  ## a delete plus an insert of the same primary key. Rows are always rebuilt
  ## fresh rather than edited in place: a fetched `RowData` shares storage
  ## with the table, so writing through it would bypass versioning.
  discard db.downloads.deleteRow(DownloadItemsTable, pk)
  db.downloads.insertRow(DownloadItemsTable, cellText(next, "id"), next)

proc downloadJson(pk: string, data: RowData): JsonNode =
  %*{
    "id": cellText(data, "id"),
    "sourceURL": cellText(data, "sourceURL"),
    "filename": cellText(data, "filename"),
    "destinationPath": cellText(data, "destinationPath"),
    "bytesExpected": cellInt(data, "bytesExpected"),
    "bytesReceived": cellInt(data, "bytesReceived"),
    "state": cellText(data, "state"),
    "errorText": cellText(data, "errorText"),
    "startedAt": cellInt(data, "startedAt"),
    "finishedAt": cellInt(data, "finishedAt"),
  }

proc bc_download_record*(id, sourceURL, filename, destinationPath: cstring,
                         bytesExpected: int64,
                         startedAt: int64): int32 {.exportc: "bc_download_record".} =
  ## Starts tracking a download. `bytesExpected` is -1 while the size is
  ## unknown. Recording an existing id restarts it: same handle, fresh row.
  clearError()
  let downloadId = requiredText(id, "download id")
  let source = requiredText(sourceURL, "source URL")
  let name = requiredText(filename, "filename")
  let destination = requiredText(destinationPath, "destination path")
  if downloadId.len == 0 or source.len == 0 or name.len == 0 or destination.len == 0:
    return ErrBadInput
  let stamp = if startedAt > 0: startedAt else: nowSeconds()
  var db = storeRef()
  catchingStore("record download"):
    let table = downloadTables(db)
    let existing = findDownload(table, downloadId)
    let next = downloadRow(downloadId, source, name, destination,
      bytesExpected, 0'i64, dsInProgress, "", stamp, 0'i64)
    if existing.found:
      replaceRow(db, existing.pk, next)
    else:
      db.downloads.insertRow(DownloadItemsTable, downloadId, next)
    Ok

proc bc_download_progress*(id: cstring, bytesReceived: int64): int32 {.exportc: "bc_download_progress".} =
  ## Advances the byte count of an in-flight download. Terminal rows ignore
  ## late progress: the finish call owns the final count.
  clearError()
  let downloadId = requiredText(id, "download id")
  if downloadId.len == 0:
    return ErrBadInput
  var db = storeRef()
  catchingStore("update download progress"):
    let table = downloadTables(db)
    let existing = findDownload(table, downloadId)
    if not existing.found:
      return ErrNotFound
    if cellText(existing.data, "state") != $dsInProgress:
      return Ok
    let next = downloadRow(
      cellText(existing.data, "id"),
      cellText(existing.data, "sourceURL"),
      cellText(existing.data, "filename"),
      cellText(existing.data, "destinationPath"),
      cellInt(existing.data, "bytesExpected"),
      bytesReceived,
      dsInProgress,
      cellText(existing.data, "errorText"),
      cellInt(existing.data, "startedAt"),
      cellInt(existing.data, "finishedAt"))
    replaceRow(db, existing.pk, next)
    Ok

proc finishDownload(id: string, state: DownloadState, bytesReceived: int64,
                    errorText: string, finishedAt: int64): int32 =
  if id.len == 0:
    setError("download id is required")
    return ErrBadInput
  var db = storeRef()
  catchingStore("finish download"):
    let table = downloadTables(db)
    let existing = findDownload(table, id)
    if not existing.found:
      return ErrNotFound
    let received = if bytesReceived >= 0: bytesReceived
      else: cellInt(existing.data, "bytesReceived")
    let stamp = if finishedAt > 0: finishedAt else: nowSeconds()
    let next = downloadRow(
      cellText(existing.data, "id"),
      cellText(existing.data, "sourceURL"),
      cellText(existing.data, "filename"),
      cellText(existing.data, "destinationPath"),
      cellInt(existing.data, "bytesExpected"),
      received,
      state,
      errorText,
      cellInt(existing.data, "startedAt"),
      stamp)
    replaceRow(db, existing.pk, next)
    Ok

proc bc_download_finish*(id: cstring, bytesReceived: int64,
                         finishedAt: int64): int32 {.exportc: "bc_download_finish".} =
  ## Marks a download done. A negative byte count keeps whatever progress
  ## recorded last, for delegates that only report completion.
  clearError()
  let downloadId = requiredText(id, "download id")
  if downloadId.len == 0:
    return ErrBadInput
  finishDownload(downloadId, dsDone, bytesReceived, "", finishedAt)

proc bc_download_fail*(id, errorText: cstring, bytesReceived: int64,
                       finishedAt: int64): int32 {.exportc: "bc_download_fail".} =
  ## Marks a download failed with the delegate's message, so retry in the
  ## popup can explain itself.
  clearError()
  let downloadId = requiredText(id, "download id")
  if downloadId.len == 0:
    return ErrBadInput
  finishDownload(downloadId, dsFailed, bytesReceived, optionalText(errorText), finishedAt)

proc bc_download_cancel*(id: cstring, finishedAt: int64): int32 {.exportc: "bc_download_cancel".} =
  ## Marks a download cancelled by the user. The partial file is the
  ## delegate's to clean up; the row stays as history.
  clearError()
  let downloadId = requiredText(id, "download id")
  if downloadId.len == 0:
    return ErrBadInput
  finishDownload(downloadId, dsCancelled, -1'i64, "", finishedAt)

proc bc_download_list*(buffer: ptr char, capacity: int32,
                       needed: ptr int32): int32 {.exportc: "bc_download_list".} =
  ## Newest-first download history for the popup, capped. Sorting happens
  ## here because the store only answers equality lookups.
  clearError()
  var db = storeRef()
  catchingStore("list downloads"):
    let table = downloadTables(db)
    var rows: seq[tuple[pk: string, data: RowData]] = @[]
    for row in rdbms.allRows(table):
      rows.add(row)
    rows.sort(proc(a, b: tuple[pk: string, data: RowData]): int =
      cmp(cellInt(b.data, "startedAt"), cellInt(a.data, "startedAt")))
    var items = newJArray()
    for row in rows[0 ..< min(rows.len, MaxDownloadResults)]:
      items.add(downloadJson(row.pk, row.data))
    emitJson(items, buffer, capacity, needed)

proc bc_download_remove*(id: cstring): int32 {.exportc: "bc_download_remove".} =
  ## Forgets one history row. The file itself is untouched: removing history
  ## must never delete user data.
  clearError()
  let downloadId = requiredText(id, "download id")
  if downloadId.len == 0:
    return ErrBadInput
  var db = storeRef()
  catchingStore("remove download"):
    let table = downloadTables(db)
    let existing = findDownload(table, downloadId)
    if not existing.found:
      return ErrNotFound
    discard db.downloads.deleteRow(DownloadItemsTable, existing.pk)
    Ok

proc bc_download_clear*(): int32 {.exportc: "bc_download_clear".} =
  ## Forgets all download history. Files on disk are untouched.
  clearError()
  var db = storeRef()
  catchingStore("clear downloads"):
    let table = downloadTables(db)
    # Collect first: deleting while the row iterator is live hangs, the
    # mutation invalidates the very sequence being walked.
    var keys: seq[string] = @[]
    for row in rdbms.allRows(table):
      keys.add(row[0])
    for key in keys:
      discard db.downloads.deleteRow(DownloadItemsTable, key)
    Ok
