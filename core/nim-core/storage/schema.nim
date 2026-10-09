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
  FeedSubscriptionsTable* = "feed_subscriptions"
  FeedArticlesTable* = "feed_articles"
  DownloadItemsTable* = "download_items"

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

proc feedSubscriptionsTable*(): DbTable =
  ## One row per feed the user chose to follow. The normalized feed URL is the
  ## primary key because the same syndication document can be discovered from
  ## several pages, and those discoveries must converge on one subscription.
  newTable(
    name = FeedSubscriptionsTable,
    primaryKey = "feedURL",
    columns = [
      newColumn("feedURL", dtText, false),
      newColumn("pageURL", dtText, false),
      newColumn("siteHost", dtText, false),
      newColumn("siteName", dtText, false),
      newColumn("feedFormat", dtText, false),
      newColumn("feedTitle", dtText, false),
      newColumn("declaredTitle", dtText, true),
      newColumn("declaredType", dtText, true),
      newColumn("faviconRemoteURL", dtText, true),
      newColumn("faviconMime", dtText, true),
      newColumn("faviconImageBase64", dtText, true),
      newColumn("subscribedAt", dtInt, false),
      newColumn("lastCheckedAt", dtInt, true),
      newColumn("lastETag", dtText, true),
      newColumn("lastModified", dtText, true),
      newColumn("lastStatus", dtText, true),
      newColumn("lastError", dtText, true),
      newColumn("autoRefreshEnabled", dtBool, false),
    ],
    primaryKeyMode = pkmManual
  )

proc feedArticlesTable*(): DbTable =
  ## Cached article rows for every subscription. Article display state and media
  ## references live here so the reader works from the store rather than the
  ## network, including offline.
  ##
  ## Boogie has no binary column type, so validated image bytes are Base64 text.
  ## Large payloads are intentionally not indexed.
  newTable(
    name = FeedArticlesTable,
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("feedURL", dtText, false),
      newColumn("guid", dtText, false),
      newColumn("canonicalURL", dtText, true),
      newColumn("title", dtText, false),
      newColumn("authorsJson", dtJson, false),
      newColumn("publishedAt", dtInt, false),
      newColumn("updatedAt", dtInt, false),
      newColumn("publishedRaw", dtText, true),
      newColumn("fetchedAt", dtInt, false),
      newColumn("summaryText", dtText, true),
      newColumn("summaryHTML", dtText, true),
      newColumn("contentText", dtText, true),
      newColumn("contentHTML", dtText, true),
      newColumn("thumbnailRemoteURL", dtText, true),
      newColumn("thumbnailMime", dtText, true),
      newColumn("thumbnailWidth", dtInt, true),
      newColumn("thumbnailHeight", dtInt, true),
      newColumn("thumbnailSource", dtText, true),
      newColumn("thumbnailImageBase64", dtText, true),
      newColumn("siteName", dtText, false),
      newColumn("siteHost", dtText, false),
      newColumn("isRead", dtBool, false),
      newColumn("isSaved", dtBool, false),
    ],
    primaryKeyMode = pkmSerial,
    foreignKeys = [
      newForeignKey("feedArticlesFeed", "feedURL", FeedSubscriptionsTable, "feedURL"),
    ]
  )

proc downloadItemsTable*(): DbTable =
  ## One row per finished or in-flight browser download. The primary key is a
  ## client-generated UUID (same manual-key pattern as feed subscriptions), so
  ## recording needs no id-return round trip and progress updates reference a
  ## stable handle from the download's first byte.
  ##
  ## `bytesExpected` is -1 while the size is unknown; `finishedAt` is 0 until
  ## the download leaves `in-progress`. Whether the file still exists is
  ## computed by the app at render time, never persisted: the filesystem is
  ## the authority and a stored flag would lie after external deletes.
  newTable(
    name = DownloadItemsTable,
    primaryKey = "id",
    columns = [
      newColumn("id", dtText, false),
      newColumn("sourceURL", dtText, false),
      newColumn("filename", dtText, false),
      newColumn("destinationPath", dtText, false),
      newColumn("bytesExpected", dtInt, false),
      newColumn("bytesReceived", dtInt, false),
      newColumn("state", dtText, false),
      newColumn("errorText", dtText, true),
      newColumn("startedAt", dtInt, false),
      newColumn("finishedAt", dtInt, false),
    ],
    primaryKeyMode = pkmManual
  )

proc applySchema*(db: var Database) =
  ## Creates any missing table and applies index definitions. Indexes are
  ## rebuilt from live rows by `createIndex`, so this is safe to re-run.
  db.history.createTableIfNotExist(historyTable())
  db.sessions.createTableIfNotExist(sessionsTable())
  db.sessions.createTableIfNotExist(windowsTable())
  db.sessions.createTableIfNotExist(tabsTable())
  db.feeds.createTableIfNotExist(feedSubscriptionsTable())
  db.feeds.createTableIfNotExist(feedArticlesTable())
  db.downloads.createTableIfNotExist(downloadItemsTable())

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

  # Reader listings select one subscription's articles and deduplicate by
  # stable identity; those are equality lookups, which is what this store
  # supports. Publication order is resolved by the caller.
  let subscriptions = db.feeds.getTable(FeedSubscriptionsTable)
  if subscriptions.isSome:
    subscriptions.get().createIndex("siteHost")
  let articles = db.feeds.getTable(FeedArticlesTable)
  if articles.isSome:
    articles.get().createIndex("feedURL")
    articles.get().createIndex("guid")
    articles.get().createIndex("canonicalURL")
