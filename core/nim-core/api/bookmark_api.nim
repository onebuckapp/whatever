# bookmark_api — bookmarks C ABI.
#
# Bookmarks live in the `bookmarks` docstore: one JSON document per bookmark,
# keyed by a stable string id. That suits the shape (nested folders, arbitrary
# tags, an `order` hint) better than columns, and the store's only query is a
# full scan, which is fine at bookmark scale.
#
# `docstore` is a value type, so each call binds a local `var` from the shared
# handle rather than reaching through it.
#
# Ownership, threading and sync: see api/abi.nim.

import std/options
import openparser/json
import boogie/stores/docstore
import ../storage/database
import ../storage/schema
import ./abi
import ./settings_api

const
  ## Upper bound on documents any single listing returns.
  MaxResults = 2000

proc bookmarkList*(buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_bookmark_list".} =
  ## Every bookmark as a JSON array, in insertion order (the store's natural
  ## order). Clamped to `MaxResults`; the UI sorts by folder and order.
  var db = storeRef()
  var document = newJArray()
  let status = catchingStore("list bookmarks"):
    var bookmarks = db.bookmarks
    for _, value in bookmarks.pairs:
      if document.len >= MaxResults: break
      document.add(value)
    Ok
  if status != Ok: return status
  emitJson(document, buffer, capacity, needed)

proc bookmarkGet*(id: cstring, buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_bookmark_get".} =
  ## One bookmark by id. `ErrNotFound` when there is no such key.
  if id.isNil or id.len == 0:
    setError("bookmark id is required")
    return ErrBadInput
  var db = storeRef()
  let status = catchingStore("read bookmark"):
    var bookmarks = db.bookmarks
    let existing = bookmarks.get($id)
    if existing.isSome:
      emitJson(existing.get, buffer, capacity, needed)
    else:
      ErrNotFound
  status

proc bookmarkSet*(id: cstring, document: cstring): int32 {.exportc: "bc_bookmark_set".} =
  ## Creates or replaces one bookmark. The document must be a JSON object;
  ## Swift owns its shape.
  if id.isNil or id.len == 0:
    setError("bookmark id is required")
    return ErrBadInput
  if document.isNil:
    setError("bookmark document is required")
    return ErrBadInput
  let parsed = parseJson($document)
  if parsed.kind != JObject:
    setError("bookmark document must be a JSON object")
    return ErrBadInput
  var db = storeRef()
  catchingStore("write bookmark"):
    var bookmarks = db.bookmarks
    bookmarks.upsert($id, parsed)
    Ok

proc bookmarkDelete*(id: cstring): int32 {.exportc: "bc_bookmark_delete".} =
  ## Deletes one bookmark. `ErrNotFound` when there was no such key.
  if id.isNil or id.len == 0:
    setError("bookmark id is required")
    return ErrBadInput
  var db = storeRef()
  catchingStore("delete bookmark"):
    var bookmarks = db.bookmarks
    if bookmarks.delete($id):
      Ok
    else:
      ErrNotFound

proc bookmarksClear*(): int32 {.exportc: "bc_bookmarks_clear".} =
  ## Removes every bookmark. Keys are collected before deleting because the
  ## store's iterator does not tolerate mutation while walking.
  var db = storeRef()
  catchingStore("clear bookmarks"):
    var bookmarks = db.bookmarks
    var doomed: seq[string] = @[]
    for key, _ in bookmarks.pairs:
      doomed.add(key)
    for key in doomed:
      discard bookmarks.delete(key)
    Ok