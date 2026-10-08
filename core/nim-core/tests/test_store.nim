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

proc charOffsetOfByte(text: string, byteOffset: int): int =
  ## How many characters come before `byteOffset`.
  ##
  ## A UTF-8 continuation byte is 10xxxxxx; everything else starts a character.
  ## This is the same conversion the Swift side has to do to turn the matcher's
  ## byte offsets into character ranges, written out here so the test can assert
  ## the two genuinely disagree rather than assuming it.
  for index in 0 ..< byteOffset:
    if (ord(text[index]) and 0xC0) != 0x80:
      inc result

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

  test "distinct addresses never collapse into each other":
    ## The collapse window only ever folds a URL into itself: visiting pages
    ## along one path in quick succession must log every address, or back
    ## navigation has entries to return to. Same-URL revisits inside the
    ## window still collapse (see above); different URLs never do, no matter
    ## how fast they follow.
    let base = "https://example.com/distinct"
    let pages = [base, base & "/products", base & "/products/tshirt"]
    for index, page in pages:
      check historyRecord(page.cstring, "Page".cstring,
        1_700_000_000'i64 + int64(index), -1) == Ok
    let entries = readRecent(200)
    for page in pages:
      var rows = 0
      for entry in entries:
        if entry["url"].getStr() == page:
          inc rows
      check rows == 1

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

  test "history fuzzy search ranks subsequence matches over url and title":
    let url = "https://fuzzy.example.net/xylophone-quantum-leaping"
    check historyRecord(url.cstring, "Quantum Leaping Papers".cstring, 1_700_000_200, -1) == Ok

    ## "qlp" is a subsequence of the title's initials, so it can only match if
    ## the matcher is doing subsequence matching rather than substring.
    let byTitle = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyFuzzySearch("qlp".cstring, 50, buffer, capacity, needed))
    check byTitle.kind == JArray
    check byTitle.len > 0

    let hit = byTitle[0]
    check hit["url"].getStr == url
    ## The positions form a subsequence of the title, in order, each landing on
    ## the character of the query it satisfied. Contiguity is deliberately not
    ## asserted: this is a subsequence matcher, so a scattered hit is a correct
    ## result and pinning the test to a contiguous run would fail the moment the
    ## matcher legitimately prefers an earlier scattered one.
    let title = hit["title"].getStr
    let titlePositions = hit["titlePositions"].getElems
    let needle = "qlp"
    check titlePositions.len == needle.len
    var previous = -1
    for index, position in titlePositions:
      let offset = position.getInt
      check offset > previous
      check offset < title.len
      check title[offset].toLowerAscii() == needle[index].toLowerAscii()
      previous = offset

    ## A token that exists only in the URL has to produce URL offsets, and those
    ## offsets have to be relative to the URL rather than to the joined
    ## candidate. "xylophone" appears nowhere in the title, so every matched byte
    ## belongs to the URL and none to the title.
    let byUrl = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyFuzzySearch("xylophone".cstring, 50, buffer, capacity, needed))
    check byUrl.len > 0
    let urlHit = byUrl[0]
    let urlText = urlHit["url"].getStr
    let urlPositions = urlHit["urlPositions"].getElems
    check urlPositions.len > 0
    check urlHit["titlePositions"].getElems.len == 0
    ## Rebasing, proved by validity: an offset counted from the start of the joined
    ## candidate would sit past the title and past most of this URL, and indexing
    ## the URL with it would run off the end or land on the wrong byte.
    for position in urlPositions:
      let offset = position.getInt
      check offset < urlText.len
      let matched = urlText[offset].toLowerAscii()
      check "xylophone".find(matched) >= 0

    ## A query nothing can match must come back as an empty array rather than an
    ## error, because `writeBuffer`'s two-phase contract reports a payload size
    ## through BC_ERR_BUFFER_TOO_SMALL and readJson checks for exactly that.
    let miss = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyFuzzySearch("zzzz-no-such-page".cstring, 50, buffer, capacity, needed))
    check miss.kind == JArray
    check miss.len == 0

  test "history fuzzy search reports positions as byte offsets, not character offsets":
    ## The positions are byte offsets into UTF-8, and the UI has to convert them
    ## before it can build ranges. This title is 17 characters but 19 bytes,
    ## because 'é' and 'ü' are two bytes each.
    ##
    ## The query is pure ASCII on purpose — see the next test for what happens
    ## when it is not. "ebra" can only match the tail of "Zebra", which starts at
    ## byte 15 and at character 12, so the two disagree and the test can tell
    ## which one the matcher reported.
    let accented = "Café Zürich Zebra"
    let url = "https://bytes.example.com/umlaut-row"
    check historyRecord(url.cstring, accented.cstring, 1_700_000_250, -1) == Ok

    let hits = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyFuzzySearch("ebra".cstring, 50, buffer, capacity, needed))
    check hits.len > 0
    let hit = hits[0]
    check hit["title"].getStr == accented
    let positions = hit["titlePositions"].getElems
    check positions.len == 4
    check positions[0].getInt == 15
    check positions[3].getInt == 18
    ## The byte offset is not the character offset, and this is the conversion
    ## the Swift side has to perform before it can build an NSRange. "Zebra"'s Z
    ## is byte 14 and character 12; its 'e' is byte 15 and character 13.
    check charOffsetOfByte(accented, 14) == 12
    check charOffsetOfByte(accented, 15) == 13
    ## And the byte really is the byte: Nim's `[]` indexes UTF-8 bytes.
    check accented[15] == 'e'
    check accented[14] == 'Z'

  test "history fuzzy search matches multi-byte query characters byte by byte":
    ## The matcher is still byte-oriented and its case folding still covers ASCII
    ## only, so a query character outside ASCII is matched as its individual
    ## bytes. What changed is which bytes it picks. A leftmost walk satisfied the
    ## query 'ü' — C3 BC — with the C3 of the 'é' and the BC of the 'ü', two
    ## different characters, because it had to take the first C3 it saw. Choosing
    ## the best alignment instead prefers the adjacent BC at byte 8 that pairs
    ## with the C3 at byte 7, which is the 'ü' itself.
    ##
    ## This is not Unicode support and must not be read as it: the bytes are
    ## still matched one at a time, so a query can still align onto bytes that do
    ## not form a character. The UI's byte-to-character conversion is still what
    ## stops a bad alignment being painted, so the Swift side keeps its guard.
    let accented = "Café Zürich Zebra"
    let url = "https://byteseek.example.com/multi-byte-row"
    check historyRecord(url.cstring, accented.cstring, 1_700_000_255, -1) == Ok

    let hits = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyFuzzySearch("ü".cstring, 50, buffer, capacity, needed))
    check hits.len > 0
    let positions = hits[0]["titlePositions"].getElems
    check positions.len == 2
    ## The two bytes of the 'ü' at offset 7, not C3 from the 'é' at offset 3.
    check positions[0].getInt == 7
    check positions[1].getInt == 8

  test "history fuzzy search on an empty query returns an empty array":
    let empty = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyFuzzySearch("".cstring, 50, buffer, capacity, needed))
    check empty.kind == JArray
    check empty.len == 0

  test "history fuzzy search ranks a tight title match above a scattered one":
    ## Two rows both match "nb", but one has them adjacent at a word start and the
    ## other only as a run across two words. The better-formed match has to come
    ## first, which is the whole reason for scoring rather than substring
    ## matching.
    ##
    ## The scattered title used to be "Nim Build Manual", which is the same match
    ## geometry as "Nim Bridges" over a longer string and so only lost under the
    ## old normalize-by-candidate-length rule — the two now score the same, which
    ## is the correct answer for two equally good matches. It has to actually be
    ## scattered to test what this test says it tests.
    check historyRecord(
      "https://rank.example.com/tight".cstring,
      "Nim Bridges".cstring, 1_700_000_260, -1) == Ok
    check historyRecord(
      "https://rank.example.com/scattered".cstring,
      "Nim manual builds".cstring, 1_700_000_261, -1) == Ok

    let hits = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyFuzzySearch("nb".cstring, 50, buffer, capacity, needed))
    check hits.len >= 2
    check hits[0]["url"].getStr == "https://rank.example.com/tight"
    check hits[0]["score"].getFloat > hits[1]["score"].getFloat

  test "history fuzzy search ranks a tight title match on a long url above a scattered one":
    ## "real" has to put "Is it real" first even though "Stream and listen"
    ## matches four scattered characters. The two rows differ in URL length on
    ## purpose: scores are normalised by candidate length, so ranking the title
    ## and URL joined let the short URL win on a worse match. Regression for
    ## that, and the reason `bestScoreFor` scores each field on its own.
    check historyRecord(
      "https://example.com/questions/is-it-real".cstring,
      "Is it real".cstring, 1_700_000_270, -1) == Ok
    check historyRecord(
      "https://a.co".cstring,
      "Stream and listen".cstring, 1_700_000_271, -1) == Ok

    let hits = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyFuzzySearch("real".cstring, 50, buffer, capacity, needed))
    check hits.len >= 2
    check hits[0]["url"].getStr == "https://example.com/questions/is-it-real"
    check hits[0]["score"].getFloat > hits[1]["score"].getFloat

  test "history fuzzy search still matches across title into url":
    ## The joined scoring is what makes a query run off the end of a title and
    ## into the URL, so scoring the fields separately must not lose it.
    check historyRecord(
      "https://github.com/login".cstring,
      "Sign in to your account".cstring, 1_700_000_280, -1) == Ok

    let hits = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      historyFuzzySearch("githb".cstring, 50, buffer, capacity, needed))
    check hits.len >= 1
    check hits[0]["url"].getStr == "https://github.com/login"
    # The match landed in the URL, so only the URL carries positions.
    check hits[0]["titlePositions"].len == 0
    check hits[0]["urlPositions"].len > 0

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
    let document = %*{"title": "Whatever", "url": "https://onebuck.app", "order": 0}
    check bookmarksClear() == Ok
    check bookmarkSet(id.cstring, ($document).cstring) == Ok

    let fetched = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      bookmarkGet(id.cstring, buffer, capacity, needed))
    check fetched["title"].getStr == "Whatever"
    check fetched["url"].getStr == "https://onebuck.app"

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