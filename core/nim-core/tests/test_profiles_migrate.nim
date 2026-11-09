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

# Migration tests: a pre-profiles store directory must move into
# `Profiles/default/` on first ensure.
#
# A separate test *process* from `test_store.nim` on purpose: the registry
# cache lives for the process, and migration only runs on a cache miss, so
# reusing that process could never exercise it twice. Each file here points
# `WHATEVER_STORE_ROOT` at its own scratch directory before any store call.
#
# The markers are plain bytes, not real store files: what is under test is
# the move itself (selection, destination conflicts, registry), and a
# rename within a volume carries content untouched by construction. Live
# round-trips against moved stores are covered by the profile tests in
# `test_store.nim`, which run against a migrated scratch dir.

import std/[envvars, os, strutils, unittest]

import openparser/json

import ../api/[abi, profile_api]

let migrateRoot = getTempDir() / "whatever-migrate-tests"

proc readRegistry(): JsonNode =
  ## Drives the two-phase protocol the way the Swift wrapper does.
  var needed: int32 = 0
  doAssert profilesEnsure(nil, 0, addr needed) == ErrBufferTooSmall
  var buffer = newString(needed.int)
  var filled: int32 = 0
  doAssert profilesEnsure(addr buffer[0], needed, addr filled) == Ok
  parseJson($buffer)

proc writeMarker(path: string, text: string) =
  createDir(parentDir(path))
  writeFile(path, text)

proc rootChildren(): seq[string] =
  ## Basenames directly under the scratch root.
  result = @[]
  for _, path in walkDir(migrateRoot):
    result.add(lastPathPart(path))

suite "legacy migration":
  test "a legacy layout moves into the default profile":
    removeDir(migrateRoot)
    createDir(migrateRoot)
    putEnv("WHATEVER_STORE_ROOT", migrateRoot)
    # A pre-profiles install: file triples plus store directories, plus an
    # unrelated file the migration must leave alone.
    writeMarker(migrateRoot / "settings.db", "legacy-settings")
    writeMarker(migrateRoot / "settings.wal", "legacy-settings-wal")
    writeMarker(migrateRoot / "history.db", "legacy-history")
    writeMarker(migrateRoot / "sessions.db", "legacy-sessions")
    writeMarker(migrateRoot / "feeds.db", "legacy-feeds")
    writeMarker(migrateRoot / "downloads.db", "legacy-downloads")
    writeMarker(migrateRoot / "bookmarks" / "index", "legacy-bookmarks")
    writeMarker(migrateRoot / "passwords" / "vault", "legacy-passwords")
    writeMarker(migrateRoot / "notes.txt", "not a store")

    let registry = readRegistry()
    check registry["profiles"].len == 1
    check registry["profiles"][0]["id"].getStr == "default"

    let home = migrateRoot / "Profiles" / "default"
    check readFile(home / "settings.db") == "legacy-settings"
    check readFile(home / "settings.wal") == "legacy-settings-wal"
    check readFile(home / "history.db") == "legacy-history"
    check readFile(home / "bookmarks" / "index") == "legacy-bookmarks"
    check readFile(home / "passwords" / "vault") == "legacy-passwords"
    # Nothing legacy left behind, the bystander untouched.
    check "settings.db" notin rootChildren()
    check "bookmarks" notin rootChildren()
    check readFile(migrateRoot / "notes.txt") == "not a store"

  test "an occupied destination is renamed aside, never deleted":
    removeDir(migrateRoot)
    createDir(migrateRoot)
    putEnv("WHATEVER_STORE_ROOT", migrateRoot)
    resetRegistryCacheForTesting()
    # A half-migrated state: legacy files at the root, and a fresh
    # placeholder already sitting where they belong.
    writeMarker(migrateRoot / "settings.db", "real-settings")
    writeMarker(migrateRoot / "Profiles" / "default" / "settings.db", "placeholder")

    discard readRegistry()

    let home = migrateRoot / "Profiles" / "default"
    check readFile(home / "settings.db") == "real-settings"
    var backups: seq[string] = @[]
    for _, path in walkDir(home):
      if lastPathPart(path).startsWith("settings.db.bak-"):
        backups.add(path)
    check backups.len == 1
    check readFile(backups[0]) == "placeholder"
    check "settings.db" notin rootChildren()
