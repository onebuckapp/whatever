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

# database — the single owner of Whatever's persistent stores.
#
# boogie holds an exclusive `flock` on a store path for that store's whole
# lifetime, so exactly one process may open a given path: a second writer
# blocks rather than failing. This module is therefore the only place in the
# app that opens a store, and it lives inside the XPC service. Nothing in the
# app process links these handles.
#
# Every store is opened with `enableConcurrency = true` so the service can
# serve XPC requests on its own queue instead of serializing every call behind
# one lock. That requires the core to be built with `--threads:on` (ARC too,
# see core/Makefile). Two consequences worth remembering at the call sites:
#
#   * `rdbms.updateRow` raises in concurrent mode. Update by delete + insert
#     when the row's primary key stays the same.
#   * `readOnly` cannot be combined with `enableConcurrency`.
#
# Boogie's crash handlers are compiled out (`-d:boogieNoCrashHandlers`): its
# default SIGTERM handler flushes and then terminates, which turns logout and
# XPC idle eviction into non-graceful exits. `shutdown` does the flushing
# instead, and the service calls it before letting the process go.

import std/os
import boogie/stores/kv
import boogie/stores/docstore
import boogie/stores/rdbms

type
  Database* = object
    ## Live handles. A `var Database` is required to mutate the docstore,
    ## which is a value type; the rdbms and kv handles are references.
    settings*: KvStore
    ## `bookmarks` is a value type and `docstore` is not concurrency-safe, so
    ## every access goes through this handle on the service's own queue.
    bookmarks*: DocumentStore
    ## The password vault: one encrypted JSON document under a fixed key.
    ## Same value-type rules as `bookmarks`.
    passwords*: DocumentStore
    history*: Store
    sessions*: Store
    feeds*: Store
    downloads*: Store
    root*: string

proc defaultRoot*(): string =
  ## Where the stores live: `~/Library/Application Support/Whatever`, which is
  ## where macOS expects an app's own state to be.
  ##
  ## Deliberately not Nim's `getAppDir()`, which despite the name is the
  ## *executable's* directory. That would put the stores inside
  ## `WhateverStore.xpc/Contents/MacOS/`, inside a signed bundle, where a code
  ## signature change would orphan them.
  ##
  ## `WHATEVER_STORE_ROOT` overrides it, which is how the test suite points the
  ## store at a scratch directory instead of the user's real data.
  let override = getEnv("WHATEVER_STORE_ROOT")
  if override.len > 0:
    return override
  getHomeDir() / "Library" / "Application Support" / "Whatever"

proc openDatabase*(root: string = defaultRoot()): Database =
  ## Opens every store, creating the directory tree if needed.
  ##
  ## Throws when a path is already locked by another process. In this app that
  ## would mean a second copy of the XPC service, which the service treats as
  ## fatal rather than hanging on the lock.
  ##
  ## Every store sets `walFlushEveryOps = 1`, so each write is durable before the
  ## call returns. That is the whole durability story, and it is deliberately not
  ## left to shutdown code: the stores live in an on-demand XPC service that
  ## launchd terminates the moment its last client disconnects, killing the
  ## process in parallel with whatever it was doing on the way out. Measured, a
  ## flush from the connection-invalidation handler is cut off part-way through.
  ## Flushing per write costs an fsync on a store that a browser writes a handful
  ## of rows to per navigation, which is a fair price for never depending on
  ## getting to run any teardown at all.
  ##
  ## Checkpointing is left on its own, larger schedule: that is the expensive
  ## rewrite of the whole table, and a stale checkpoint costs replay time, not
  ## data.
  createDir(root)
  result = Database(
    root: root,
    settings: newKvStore(
      root / "settings",
      ksmDisk,
      enableWal = true,
      checkpointEveryOps = 64'u32,
      walFlushEveryOps = 1'u32,
      enableConcurrency = true
    ),
    bookmarks: openDocumentStore(
      root / "bookmarks",
      name = "bookmarks",
      checkpointEveryOps = 256'u32,
      walFlushEveryOps = 1'u32
    ),
    passwords: openDocumentStore(
      root / "passwords",
      name = "passwords",
      checkpointEveryOps = 256'u32,
      walFlushEveryOps = 1'u32
    ),
    history: newStore(
      root / "history",
      smDisk,
      enableWal = true,
      checkpointEveryOps = 512'u32,
      walFlushEveryOps = 1'u32,
      enableConcurrency = true
    ),
    sessions: newStore(
      root / "sessions",
      smDisk,
      enableWal = true,
      # Sessions are rewritten wholesale, so checkpoint often and keep the
      # WAL short between snapshots.
      checkpointEveryOps = 32'u32,
      walFlushEveryOps = 1'u32,
      enableConcurrency = true
    ),
    feeds: newStore(
      root / "feeds",
      smDisk,
      enableWal = true,
      checkpointEveryOps = 128'u32,
      walFlushEveryOps = 1'u32,
      enableConcurrency = true
    ),
    downloads: newStore(
      root / "downloads",
      smDisk,
      enableWal = true,
      checkpointEveryOps = 128'u32,
      walFlushEveryOps = 1'u32,
      enableConcurrency = true
    )
  )

proc shutdown*(db: var Database) =
  ## Flushes and closes every store. Safe to call once; the process is
  ## expected to be on its way out.
  db.settings.close()
  db.bookmarks.close()
  db.passwords.close()
  db.history.close()
  db.sessions.close()
  db.feeds.close()
  db.downloads.close()
