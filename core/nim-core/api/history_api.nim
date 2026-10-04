# history_api — browsing history C ABI.
#
# One row per visited page, in the `history` rdbms table. `rdbms.where` is
# equality-only (no ranges, no OR, no ORDER BY), which shapes the whole
# surface: day queries hit an indexed `dayBucket` text column, the recency list
# walks `allRows` in primary-key order and truncates, and text search is a
# bounded scan with an early cap.
#
# `RowData` is a `tables.OrderedTable`, but openparser's JSON exports its own
# `hasKey` and `[]`, which would otherwise shadow the table versions. Row reads
# go through `tables.hasKey` / `tables.[]` for that reason, and rows are built
# with explicit arrays rather than `row("k" -> v)` because openparser's `to`
# takes precedence over the `->` conversion.
#
# Ownership, threading and sync: see api/abi.nim.

import std/[algorithm, options, strutils, tables, times]
import openparser/json
# Leaf module on purpose: it pulls in nimsimd, which `openparser/json` already
# brings, and nothing else. Reaching for the `openparser` umbrella instead would
# drag the QR ciphers and nimcypher into the archive.
import openparser/fuzzy
import boogie/stores/rdbms
import ../storage/database
import ../storage/schema
import ./abi
import ./settings_api

const
  ## Fallback collapse window, used when a caller passes a negative value.
  ##
  ## A revisit of the same URL inside the window updates the existing row instead
  ## of appending a near-duplicate, so opening one page in several tabs seconds
  ## apart reads as a single visit. The window comes from the caller because it
  ## is a user setting; this is only the value assumed when none is supplied.
  DefaultCollapseWindowSecs = 10'i64

  ## Ceiling on rows one interactive fuzzy query will score, halved repeatedly
  ## rather than truncated once. See `thin`.
  FuzzyScanLimit = 2000

  ## Upper bound on rows any single listing returns.
  MaxResults = 500

  ## Separator between the title and URL halves of a fuzzy candidate.
  ##
  ## A space, which `fuzzy.isWordStart` counts as a word boundary, so a match on
  ## the first character of the URL gets the same boundary bonus a word start
  ## would otherwise get.
  FuzzyFieldSeparator = " "

type
  Visit = tuple[visitedAt: int64, entry: JsonNode]
    ## A listing candidate, ordered by its timestamp so the newest survive the
    ## truncation below.

  Candidate = object
    ## One history row, held as plain fields rather than a `JsonNode`.
    ##
    ## A fuzzy query scores every scanned row, so building the JSON for each one
    ## would allocate a tree per row for the sake of the handful that survive.
    pk: string
    url: string
    title: string
    host: string
    firstVisited: int64
    lastVisited: int64
    visitCount: int64

# MARK: - Reading rows

proc cellOf(data: RowData, key: string, kind: DataType): Value =
  ## One column, yielding a null value when it is absent or of another type.
  ## Defensive on purpose: a single malformed row must not take out the whole
  ## history list.
  if not tables.hasKey(data, key):
    return newNullValue()
  let value = tables.`[]`(data, key)
  if value.kind == kind: value else: newNullValue()

proc textOf(data: RowData, key: string): string =
  let value = cellOf(data, key, dtText)
  if value.kind == dtText: value.strVal else: ""

proc intOf(data: RowData, key: string): int64 =
  let value = cellOf(data, key, dtInt)
  if value.kind == dtInt: value.intVal else: 0'i64

proc entryJson(pk: string, data: RowData): JsonNode =
  %*{
    "id": pk,
    "url": textOf(data, "url"),
    "title": textOf(data, "title"),
    "host": textOf(data, "host"),
    "firstVisited": intOf(data, "firstVisited"),
    "lastVisited": intOf(data, "lastVisited"),
    "visitCount": intOf(data, "visitCount"),
  }

# MARK: - Derived values

proc hostOf(url: string): string =
  ## Host portion of a URL, or the whole string when it has none. Used for
  ## grouping and for the `host` index.
  var rest = url
  let schemeEnd = rest.find("://")
  if schemeEnd >= 0:
    rest = rest[(schemeEnd + 3) .. ^1]
  for terminator in {'/', '?', '#'}:
    let cut = rest.find(terminator)
    if cut >= 0:
      rest = rest[0 ..< cut]
  let userEnd = rest.find('@')
  if userEnd >= 0:
    rest = rest[(userEnd + 1) .. ^1]
  let portStart = rest.find(':')
  if portStart >= 0:
    rest = rest[0 ..< portStart]
  result = rest.toLowerAscii()

proc dayBucket(at: int64): string =
  ## `YYYY-MM-DD` in local time, so "history for today" matches the user's own
  ## clock rather than UTC's. `fromUnix` yields UTC, which `inZone(local())`
  ## converts.
  fromUnix(at).inZone(local()).format("yyyy-MM-dd")

proc visitRow(url, title, host, bucket: string, first, last, count: int64): RowData =
  rdbms.row([
    ("url", newTextValue(url)),
    ("title", newTextValue(title)),
    ("host", newTextValue(host)),
    ("firstVisited", newIntValue(first)),
    ("lastVisited", newIntValue(last)),
    ("visitCount", newIntValue(count)),
    ("dayBucket", newTextValue(bucket)),
  ])

# MARK: - Listing

proc newestFirst(candidates: var seq[Visit]): JsonNode =
  ## Sorts by timestamp descending and flattens to a JSON array.
  candidates.sort(proc(a, b: Visit): int = cmp(b.visitedAt, a.visitedAt))
  var document = newJArray()
  for candidate in candidates.mitems:
    document.add(candidate.entry)
  document

proc recentVisits(table: DbTable, wanted: int): seq[Visit] =
  ## The `wanted` most recently visited rows.
  ##
  ## `allRows` iterates in primary-key order and this table's keys are serial
  ## numbers, so the walk is oldest-first. Keeping only the newest means
  ## clearing the window whenever a newer row displaces its oldest member, which
  ## bounds memory without ever walking the table twice.
  var candidates: seq[Visit] = @[]
  for row in table.allRows:
    let (pk, data) = row
    let visitedAt = intOf(data, "lastVisited")
    if candidates.len >= wanted:
      candidates.setLen(0)
    candidates.add((visitedAt, entryJson(pk, data)))
  candidates

# MARK: - Exports

proc historyRecord*(url, title: cstring, visitedAt: int64,
                    collapseWindowSecs: int64): int32 {.exportc: "bc_history_record".} =
  ## Records a visit to `url`, or collapses it into the existing row when the
  ## same URL was visited within `collapseWindowSecs`.
  ##
  ## A negative `collapseWindowSecs` selects `DefaultCollapseWindowSecs`; zero is
  ## honoured and disables collapsing, so every visit becomes its own row.
  if url.isNil or url.len == 0:
    setError("history url is required")
    return ErrBadInput
  let collapseWindow =
    if collapseWindowSecs < 0'i64: DefaultCollapseWindowSecs else: collapseWindowSecs
  let target = $url
  let pageTitle = if title.isNil or title.len == 0: target else: $title
  let visited = if visitedAt > 0'i64: visitedAt else: getTime().toUnix()
  let bucket = dayBucket(visited)
  let host = hostOf(target)

  catchingStore("record history"):
    var db = storeRef()
    let table = db.history.getTable(HistoryTable).get()
    for row in table.where("url", newTextValue(target)):
      let (pk, data) = row
      let previous = intOf(data, "lastVisited")
      if previous == 0 or visited - previous > collapseWindow:
        break
      # Same page moments apart: bump the existing row rather than adding a
      # near-duplicate. `updateRow` raises in concurrent mode, so the
      # replacement is delete + insert under the same primary key, which keeps
      # the row's identity stable for the UI.
      discard db.history.deleteRow(HistoryTable, pk)
      db.history.insertRow(HistoryTable, pk,
        visitRow(target, pageTitle, host, bucket,
          intOf(data, "firstVisited"), visited, intOf(data, "visitCount") + 1))
      return Ok
    discard db.history.insertRow(HistoryTable,
      visitRow(target, pageTitle, host, bucket, visited, visited, 1'i64))
    Ok

proc historyRecent*(limit: int32, buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_history_recent".} =
  ## Most recently visited entries as a JSON array, newest first. `limit` is
  ## clamped to `MaxResults`.
  var document = newJArray()
  let status = catchingStore("list history"):
    let db = storeRef()
    let table = db.history.getTable(HistoryTable).get()
    var candidates = recentVisits(table, max(1'i32, min(limit, int32(MaxResults))).int)
    document = newestFirst(candidates)
    Ok
  if status != Ok: return status
  emitJson(document, buffer, capacity, needed)

proc historyByDay*(day: cstring, buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_history_by_day".} =
  ## Entries for one `YYYY-MM-DD` bucket, newest first. An indexed equality
  ## query rather than a scan, which is why `dayBucket` exists.
  if day.isNil or day.len == 0:
    setError("history day is required")
    return ErrBadInput
  let bucket = $day
  var entries = newJArray()
  let status = catchingStore("list history by day"):
    let db = storeRef()
    let table = db.history.getTable(HistoryTable).get()
    var candidates: seq[Visit] = @[]
    for row in table.where("dayBucket", newTextValue(bucket)):
      let (pk, data) = row
      if candidates.len >= MaxResults: break
      candidates.add((intOf(data, "lastVisited"), entryJson(pk, data)))
    entries = newestFirst(candidates)
    Ok
  if status != Ok: return status
  emitJson(entries, buffer, capacity, needed)

# MARK: - Fuzzy search

proc candidateOf(pk: string, data: RowData): Candidate =
  Candidate(
    pk: pk,
    url: textOf(data, "url"),
    title: textOf(data, "title"),
    host: textOf(data, "host"),
    firstVisited: intOf(data, "firstVisited"),
    lastVisited: intOf(data, "lastVisited"),
    visitCount: intOf(data, "visitCount"))

proc candidateText(candidate: Candidate): string =
  ## What the matcher scores: the title and the URL as one string.
  ##
  ## A page is identified by either half, and a query like "githb" should be able
  ## to run off the end of a title and into the URL. The cost is that
  ## `fuzzyScoreImpl` normalises by the whole candidate's length, so a long URL
  ## pulls down a score a title earned on its own; `minScore` stays at 0 for that
  ## reason rather than trying to compensate for it here.
  if candidate.title.len == 0:
    candidate.url
  else:
    candidate.title & FuzzyFieldSeparator & candidate.url

proc thin(kept: var seq[Candidate], cap: int) =
  ## Halves `kept` in place, keeping every second entry.
  ##
  ## `allRows` walks primary-key order, which for this table's serial keys is
  ## oldest-first, so simply stopping after `cap` rows would score nothing but the
  ## oldest history a user ever accumulated — and the old substring search did
  ## exactly that. Dropping every second entry instead keeps an even spread over
  ## everything walked so far, so a page first visited years ago and opened since
  ## every day stays findable. Repeating the halving gives a stride of 2, 4, 8
  ## without ever needing the row count up front.
  var survivors: seq[Candidate] = @[]
  for index, candidate in kept:
    if index mod 2 == 0:
      survivors.add(candidate)
  kept = survivors

proc fuzzyCandidates(table: DbTable): seq[Candidate] =
  ## Up to `FuzzyScanLimit` rows, spread across the whole table.
  var kept: seq[Candidate] = @[]
  for row in table.allRows:
    kept.add(candidateOf(row[0], row[1]))
    if kept.len >= FuzzyScanLimit * 2:
      thin(kept, FuzzyScanLimit)
  kept

proc fuzzyEntryJson(candidate: Candidate, matched: FuzzyMatch): JsonNode =
  ## One result, with the match positions split back onto the two fields.
  ##
  ## The positions `fuzzySearch` reports are byte offsets into the combined
  ## candidate string, so they have to be divided here rather than in Swift:
  ## splitting in Nim keeps the separator an implementation detail and leaves
  ## each field's positions relative to that field alone, which is the only form
  ## the UI can use to build ranges.
  var titlePositions: seq[int] = @[]
  var urlPositions: seq[int] = @[]
  let titleBytes = candidate.title.len
  if titleBytes == 0:
    # The candidate is the bare URL, so every offset is already a URL offset.
    urlPositions = matched.positions
  else:
    for position in matched.positions:
      if position < titleBytes:
        titlePositions.add(position)
      elif position > titleBytes:
        # One past the separator, which sits at `titleBytes`.
        urlPositions.add(position - titleBytes - FuzzyFieldSeparator.len)
      # A match landing exactly on the separator is dropped: there is no
      # character there to highlight.
  # Built outside the `%*` macro: `Float64` is not resolvable from inside it,
  # and the score is the one value here that is not an integer.
  result = %*{
    "id": candidate.pk,
    "url": candidate.url,
    "title": candidate.title,
    "host": candidate.host,
    "firstVisited": candidate.firstVisited,
    "lastVisited": candidate.lastVisited,
    "visitCount": candidate.visitCount,
    "titlePositions": titlePositions,
    "urlPositions": urlPositions,
  }
  result["score"] = newJFloat(matched.score)

proc historyFuzzySearch*(query: cstring, limit: int32, buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_history_fuzzy_search".} =
  ## Ranks history by subsequence match against the query, best first.
  ##
  ## Every query character must appear in the row, in order but not necessarily
  ## contiguously, which is what `openparser/fuzzy` scores: consecutive runs,
  ## word-boundary hits and gap penalties. Ranking comes from the matcher rather
  ## than from recency, so a page visited once and named exactly what you typed
  ## can outrank the one you open every morning.
  ##
  ## Each row is scored as its title and URL joined, and the reported positions
  ## are split back onto those two fields, so one row is one result however many
  ## fields matched.
  ##
  ## `caseSensitive` is left at openparser's default of false and `minScore` at 0.
  ## Scores are normalised by candidate length, so a gappy match across a long
  ## URL can land below zero; letting those through would fill the list with
  ## rows that barely matched at all.
  let db = storeRef()
  let needle = if query.isNil: "" else: $query
  let wanted = max(1'i32, min(limit, int32(MaxResults))).int
  var document = newJArray()
  let status = catchingStore("fuzzy search history"):
    # An empty query returns an empty array rather than an error, because
    # `writeBuffer`'s two-phase contract means the caller learns the payload
    # size from `ErrBufferTooSmall` and anything else here would read as a
    # failure to Swift.
    if needle.len > 0:
      let table = db.history.getTable(HistoryTable).get()
      let candidates = fuzzyCandidates(table)
      var texts: seq[string] = @[]
      var byText = initTable[string, Candidate]()
      for candidate in candidates:
        let text = candidateText(candidate)
        if byText.hasKey(text):
          # Two rows can only collide here if they share a URL, which the
          # collapse window normally prevents. The newer row wins, and the text
          # is left out of `texts` a second time so one row is scored once and
          # cannot appear in the results twice.
          if byText[text].lastVisited >= candidate.lastVisited:
            continue
          byText[text] = candidate
        else:
          texts.add(text)
          byText[text] = candidate
      let matches = fuzzySearch(needle, texts, FuzzyOptions(limit: wanted))
      for matched in matches:
        if byText.hasKey(matched.text):
          document.add(fuzzyEntryJson(byText[matched.text], matched))
    Ok
  if status != Ok: return status
  emitJson(document, buffer, capacity, needed)

proc historyDelete*(id: cstring): int32 {.exportc: "bc_history_delete".} =
  ## Deletes one entry by primary key. `ErrNotFound` when no such row exists.
  if id.isNil or id.len == 0:
    setError("history id is required")
    return ErrBadInput
  let target = $id
  let status = catchingStore("delete history"):
    let db = storeRef()
    ## Existence is checked first rather than read off `deleteRow`: in
    ## concurrent mode boogie's `deleteRow` returns `true` for any primary key
    ## it is handed, including one that was never there.
    if not db.history.getRow(HistoryTable, target).isSome:
      ErrNotFound
    else:
      discard db.history.deleteRow(HistoryTable, target)
      Ok
  status

proc historyDeleteBefore*(cutoff: int64, removed: ptr int32): int32 {.exportc: "bc_history_delete_before".} =
  ## Deletes every entry whose last visit is older than `cutoff` (a Unix
  ## timestamp). Reports the number of rows removed through `removed`, which may
  ## be NULL.
  var count = 0'i32
  let status = catchingStore("prune history"):
    let db = storeRef()
    let table = db.history.getTable(HistoryTable).get()
    var doomed: seq[string] = @[]
    for row in table.allRows:
      let (pk, data) = row
      if intOf(data, "lastVisited") < cutoff:
        doomed.add(pk)
    for pk in doomed:
      discard db.history.deleteRow(HistoryTable, pk)
    count = int32(doomed.len)
    Ok
  if status != Ok: return status
  if not removed.isNil:
    removed[] = count
  Ok

proc historyClear*(): int32 {.exportc: "bc_history_clear".} =
  ## Removes all history. Rows are deleted rather than the table dropped, so the
  ## next insert keeps working without a schema check.
  catchingStore("clear history"):
    let db = storeRef()
    let table = db.history.getTable(HistoryTable).get()
    var doomed: seq[string] = @[]
    for row in table.allRows:
      doomed.add(row[0])
    for pk in doomed:
      discard db.history.deleteRow(HistoryTable, pk)
    Ok