# Storage C ABI tests.
#
# Exercises the exports through the same entry points Swift uses, against a
# throwaway store directory, so buffer sizing, JSON round-trips, and the query
# shapes are all covered.
#
# `WHATEVER_STORE_ROOT` points the store at a scratch directory; the handles
# open on the first export call, so it has to be set before any test runs.

import std/[envvars, os, sequtils, strutils, times, unittest]

import openparser/json

import ../api/[abi, bookmark_api, history_api, session_api, settings_api]

type
  JsonCall = proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32
    ## Shape shared by every export that returns JSON through the two-phase
    ## buffer protocol.

proc readJson(call: JsonCall): JsonNode =
  ## Drives the protocol the way the Swift wrapper does: ask for the size, then
  ## fill an exactly sized buffer.
  var needed: int32 = 0
  check call(nil, 0'i32, addr needed) == ErrBufferTooSmall
  var buffer = newString(needed.int)
  var filled: int32 = 0
  check call(addr buffer[0], needed, addr filled) == Ok
  result = parseJson($buffer)

proc readRecent(limit: int): seq[JsonNode] =
  ## Most recent history entries as an array. An empty result comes back as an
  ## empty array rather than a null node.
  let node = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
    historyRecent(int32(limit), buffer, capacity, needed))
  if node.kind == JArray:
    for entry in node.items:
      result.add(entry)

let scratchRoot = getTempDir() / "whatever-store-tests"

## Cleared once, at load time, rather than per test: the store handles open on
## the first export call and boogie holds an exclusive file lock on the root for
## their whole lifetime. Wiping the directory between tests would unlink files
## underneath the open handles, so tests instead scope their assertions to
## unique URLs and ids.
removeDir(scratchRoot)
createDir(scratchRoot)
putEnv("WHATEVER_STORE_ROOT", scratchRoot)

suite "store c abi":
  test "settings round trip through the two-phase buffer":
    let document = %*{"general": {"startup": "restore"}, "web": {"zoom": 1.25}}
    let text = $document
    check settingsSet(($text).cstring, nil) == Ok

    ## Phase one asks for the size.
    var needed: int32 = 0
    check settingsGet(nil, 0, addr needed) == ErrBufferTooSmall
    check needed == int32(text.len + 1)

    ## Phase two fills an exactly sized buffer.
    var buffer = newString(needed.int)
    var filled: int32 = 0
    check settingsGet(addr buffer[0], needed, addr filled) == Ok
    let loaded = parseJson($buffer)
    check loaded["general"]["startup"].getStr == "restore"
    check loaded["web"]["zoom"].getFloat == 1.25

  test "settings reject anything that is not an object":
    ## A document that parses as a string or array would silently lose every
    ## field on the Swift side, so it has to be refused here.
    check settingsSet("\"scalar\"".cstring, nil) == ErrBadInput
    check settingsSet("[1,2,3]".cstring, nil) == ErrBadInput
    check settingsSet(nil, nil) == ErrBadInput

  test "schema versions agree on a fresh store":
    ## The core's expected version is what it writes; the stored one is what is
    ## on disk. Both land at 1 on a new store.
    check coreSchemaVersion() == int32(1)
    check storedSchemaVersion() == int32(1)

  test "the collapse window comes from the caller":
    ## The window is a user setting, so it has to be honoured per call: zero
    ## disables collapsing, and a window wide enough to cover the gap folds the
    ## second visit into the first row.
    let url = "https://example.com/windowed"
    check historyRecord(url.cstring, "First".cstring, 1_700_000_500, 0'i64) == Ok
    check historyRecord(url.cstring, "Second".cstring, 1_700_000_600, 0'i64) == Ok
    var rows = readRecent(10).filterIt(it["url"].getStr() == url)
    check rows.len == 2

    let wide = "https://example.com/wide"
    check historyRecord(wide.cstring, "First".cstring, 1_700_000_700, 600'i64) == Ok
    check historyRecord(wide.cstring, "Second".cstring, 1_700_001_000, 600'i64) == Ok
    rows = readRecent(10).filterIt(it["url"].getStr() == wide)
    check rows.len == 1
    check rows[0]["visitCount"].getInt() == 2

  test "history collapses rapid revisits":
    let url = "https://example.com/collapsed"
    check historyRecord(url.cstring, "Example".cstring, 1_700_000_000, -1) == Ok
    ## Same URL five seconds later: the same row, bumped rather than duplicated.
    check historyRecord(url.cstring, "Example".cstring, 1_700_000_005, -1) == Ok
    ## Same URL well outside the window: a separate visit.
    check historyRecord(url.cstring, "Example".cstring, 1_700_000_100, -1) == Ok

    let entries = readRecent(200)
    var rows = 0
    for entry in entries:
      if entry["url"].getStr == url:
        inc rows
        check entry["visitCount"].getInt >= 1
    check rows == 2

  test "history by day matches the local-time bucket":
    let url = "https://example.com/day"
    let visitedAt = 1_700_000_000'i64
    check historyRecord(url.cstring, "Day".cstring, visitedAt, -1) == Ok

    ## The same bucket `dayBucket` derives internally.
    let bucket = fromUnix(visitedAt).inZone(local()).format("yyyy-MM-dd")
    let entries = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyByDay(bucket.cstring, buffer, capacity, needed))
    var hit = false
    for entry in entries:
      if entry["url"].getStr == url:
        hit = true
        ## `firstVisited` must survive the collapse path.
        check entry["firstVisited"].getInt == visitedAt
    check hit

  test "history search covers url and title, and misses cleanly":
    let url = "https://searchable.example.org/needle"
    check historyRecord(url.cstring, "Findable Title".cstring, 1_700_000_200, -1) == Ok

    let byUrl = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historySearch("searchable".cstring, 50, buffer, capacity, needed))
    check byUrl.kind == JArray
    check byUrl.len > 0

    let byTitle = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historySearch("findable".cstring, 50, buffer, capacity, needed))
    check byTitle.len > 0

    ## No LIKE in the store, so search is a scan; it must still return an empty
    ## array rather than an error when nothing matches.
    let miss = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historySearch("zzzz-no-such-page".cstring, 50, buffer, capacity, needed))
    check miss.kind == JArray
    check miss.len == 0

  test "history delete removes exactly one entry":
    let url = "https://example.com/deletable"
    ## A URL that no other test uses, so an earlier test's rows cannot make
    ## the delete look like a no-op or hit the wrong id.
    check historyRecord(url.cstring, "Doomed".cstring, 1_700_000_300, -1) == Ok

    var targets: seq[string] = @[]
    for entry in readRecent(500):
      if entry["url"].getStr == url:
        targets.add(entry["id"].getStr)
    check targets.len == 1
    let target = targets[0]

    check historyDelete(target.cstring) == Ok
    ## A second delete reports not-found rather than pretending to succeed.
    check historyDelete(target.cstring) == ErrNotFound

    for entry in readRecent(500):
      check entry["url"].getStr != url

  test "history delete-before prunes only old entries":
    check historyRecord("https://example.com/old".cstring, "Old".cstring, 1_600_000_000, -1) == Ok
    check historyRecord("https://example.com/new".cstring, "New".cstring, 1_700_000_400, -1) == Ok

    var removed: int32 = 0
    check historyDeleteBefore(1_650_000_000, addr removed) == Ok
    check removed >= 1

    var keptNew = false
    for entry in readRecent(200):
      check entry["url"].getStr != "https://example.com/old"
      if entry["url"].getStr == "https://example.com/new":
        keptNew = true
    check keptNew

  test "history clear empties the table":
    check historyClear() == Ok
    check readRecent(200).len == 0

  test "bookmarks round trip":
    let id = "bookmark-1"
    let document = %*{"title": "Whatever", "url": "https://onebuckapps.dev", "order": 0}
    check bookmarksClear() == Ok
    check bookmarkSet(id.cstring, ($document).cstring) == Ok

    let fetched = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      bookmarkGet(id.cstring, buffer, capacity, needed))
    check fetched["title"].getStr == "Whatever"
    check fetched["url"].getStr == "https://onebuckapps.dev"

    let all = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      bookmarkList(buffer, capacity, needed))
    check all.kind == JArray
    check all.len == 1

    check bookmarkDelete(id.cstring) == Ok
    check bookmarkGet(id.cstring, nil, 0, nil) == ErrNotFound

  test "bookmarks reject bad input":
    check bookmarkSet("bookmark-2", "\"scalar\"".cstring) == ErrBadInput
    check bookmarkSet("", "{}".cstring) == ErrBadInput
    check bookmarkSet("bookmark-2", nil) == ErrBadInput

  test "bookmarks clear removes everything":
    check bookmarksClear() == Ok
    check bookmarkSet("b1", ($(%* {"title": "One"})).cstring) == Ok
    check bookmarkSet("b2", ($(%* {"title": "Two"})).cstring) == Ok
    check bookmarksClear() == Ok
    let remaining = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      bookmarkList(buffer, capacity, needed))
    check remaining.len == 0

  test "session round trip, and save replaces rather than accumulates":
    let snapshot = %*{
      "version": 1,
      "windows": [{
        "frame": {"x": 10.0, "y": 20.0, "width": 1300.0, "height": 840.0},
        "selectedTabID": 4,
        "layout": "single",
        "tabs": [
          {
            "id": 4,
            "url": "https://example.com/a",
            "history": ["https://example.com/a", "https://example.com/b"],
            "historyIndex": 1,
          },
        ],
      }],
    }
    check sessionSave(($snapshot).cstring) == Ok

    let loaded = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      sessionLoad(buffer, capacity, needed))
    check loaded["version"].getInt == 1
    check loaded["windows"].len == 1
    ## The per-tab back/forward list is what makes Back work after a restart.
    check loaded["windows"][0]["tabs"][0]["history"].len == 2
    check loaded["windows"][0]["tabs"][0]["historyIndex"].getInt == 1

    let smaller = %*{"version": 1, "windows": []}
    check sessionSave(($smaller).cstring) == Ok
    let replaced = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      sessionLoad(buffer, capacity, needed))
    check replaced["windows"].len == 0

  test "session rejects non-objects and clear resets":
    check sessionSave("[]".cstring) == ErrBadInput
    check sessionSave(nil) == ErrBadInput
    check sessionClear() == Ok
    ## A cleared session reads back as an empty object, the same as a fresh
    ## install: always parseable, never a bare empty string.
    let cleared = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      sessionLoad(buffer, capacity, needed))
    check cleared.kind == JObject
    check cleared.len == 0