# schema — table definitions and the on-disk version key.
#
# boogie has no migration framework and `createTableIfNotExist` ignores the
# columns it is handed when the table already exists, so changing a column
# definition here does nothing on its own. Every shape change bumps
# `SchemaVersion` and adds a step to `migrate`, which runs against live stores
# on open.
#
# Foreign keys are RESTRICT only, so deletes go children-first.

import std/options
import boogie/stores/rdbms
# `docstore` is deliberately not imported: it re-exports openparser's JSON,
# whose `[]` overloads on `JsonNode` shadow `Option`'s. Unwrap options with
# `std/options` instead.
import ./database

const
  ## Bumped whenever a table shape changes. Stored in the settings kv store
  ## so a fresh install and an upgrade take the same path.
  SchemaVersion* = 1

  SettingsDocKey* = "settings"
  SchemaVersionKey* = "schema.version"

  HistoryTable* = "history"
  SessionsTable* = "sessions"
  WindowsTable* = "windows"
  TabsTable* = "tabs"

proc settingsTable*(): DbTable =
  ## App settings as one JSON document under a single key, so a schema bump
  ## is one version check rather than a sweep over per-key migrations.
  newTable(
    name = "settings",
    primaryKey = "key",
    columns = [
      newColumn("key", dtText, false),
      newColumn("value", dtText, false),
    ],
    primaryKeyMode = pkmManual
  )

proc historyTable*(): DbTable =
  ## One row per visited page. `dayBucket` is a `YYYY-MM-DD` text column so
  ## "history for today" is an indexed equality query: `rdbms.where` handles
  ## equality only, with no ranges, no OR and no ORDER BY.
  newTable(
    name = HistoryTable,
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("url", dtText, false),
      newColumn("title", dtText, false),
      newColumn("host", dtText, false),
      newColumn("firstVisited", dtInt, false),
      newColumn("lastVisited", dtInt, false),
      newColumn("visitCount", dtInt, false),
      newColumn("dayBucket", dtText, false),
    ],
    primaryKeyMode = pkmSerial
  )

proc sessionsTable*(): DbTable =
  ## The current session snapshot. One row keyed by `"current"` holding the
  ## whole serialized session: a snapshot is always read and written whole, and
  ## a single row is atomic where a multi-table rewrite would not be.
  newTable(
    name = SessionsTable,
    primaryKey = "key",
    columns = [
      newColumn("key", dtText, false),
      newColumn("document", dtText, false),
      newColumn("savedAt", dtInt, false),
    ],
    primaryKeyMode = pkmManual
  )

proc windowsTable*(): DbTable =
  ## Per-window rows for querying a session rather than replaying it (finding
  ## every tab pointing at a URL, for instance). Snapshots do not go through
  ## these; see api/session_api.nim for why.
  newTable(
    name = WindowsTable,
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("frameX", dtFloat, false),
      newColumn("frameY", dtFloat, false),
      newColumn("frameWidth", dtFloat, false),
      newColumn("frameHeight", dtFloat, false),
      newColumn("selectedTabID", dtInt, true),
      newColumn("layout", dtText, false),
      newColumn("leadingTabID", dtInt, true),
      newColumn("trailingTabID", dtInt, true),
      newColumn("splitRatio", dtFloat, true),
    ],
    primaryKeyMode = pkmSerial
  )

proc tabsTable*(): DbTable =
  newTable(
    name = TabsTable,
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("windowID", dtInt, false),
      newColumn("position", dtInt, false),
      newColumn("url", dtText, false),
      newColumn("title", dtText, false),
      newColumn("isPinned", dtBool, false),
      newColumn("privacyMode", dtText, false),
      newColumn("recordsHistory", dtBool, false),
      # The tab's own back/forward URL list and its index, so Back still
      # works after a restart.
      newColumn("history", dtText, false),
      newColumn("historyIndex", dtInt, false),
    ],
    primaryKeyMode = pkmSerial,
    foreignKeys = [
      newForeignKey("tabsWindow", "windowID", WindowsTable, "id"),
    ]
  )

proc applySchema*(db: var Database) =
  ## Creates any missing table and applies index definitions. Indexes are
  ## rebuilt from live rows by `createIndex`, so this is safe to re-run.
  db.history.createTableIfNotExist(historyTable())
  db.sessions.createTableIfNotExist(sessionsTable())
  db.sessions.createTableIfNotExist(windowsTable())
  db.sessions.createTableIfNotExist(tabsTable())

  # History is queried by URL (to collapse repeats), by day, and by host far
  # more often than it is written.
  let history = db.history.getTable(HistoryTable)
  if history.isSome:
    let table = history.get()
    table.createIndex("url")
    table.createIndex("dayBucket")
    table.createIndex("host")

  let tabs = db.sessions.getTable(TabsTable)
  if tabs.isSome:
    tabs.get().createIndex("windowID")