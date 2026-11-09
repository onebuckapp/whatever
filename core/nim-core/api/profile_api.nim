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

# profile_api — browser profile registry and the active-profile switch.
#
# A profile is a whole store directory: `<root>/Profiles/<id>/` holds the
# seven store directories, so history, bookmarks, passwords, sessions,
# feeds, downloads and settings are isolated by construction, and deleting
# a profile is deleting a directory. The registry (`Profiles/registry.json`)
# maps ids to display names plus creation and last-use timestamps.
#
# Every store-touching export serves the *active* profile: `bc_profile_use`
# (or the lighter `bc_profile_activate`) selects it, and `storeRef` /
# `ensureOpen` in settings_api resolve it. The XPC service sets it from the
# calling connection's bound profile before each job (see
# StoreServiceHandler.serve), which is correct because the core executor
# runs jobs serially on one thread: set-then-use inside one job cannot
# interleave with another connection's job. There is deliberately no profile
# parameter on the store exports — the binding lives in exactly that one
# place rather than on every signature.
#
# The registry is cached in memory after the first load. Only this process
# ever writes it, and every mutation goes through the procs below, so the
# cache cannot go stale; per-job activation then validates against memory
# instead of re-reading a file on every keystroke.
#
# A caller that never binds a profile — the app before it learns about
# profiles, or a fresh test — resolves to the most recently used one. That
# fallback is what keeps single-profile behavior working unchanged; bound
# callers always select explicitly. Ownership, threading and sync: see
# api/abi.nim.

import std/[os, strutils, times]
import openparser/json
import ../storage/database
import ./abi

const
  ProfilesDirName = "Profiles"
  RegistryFileName = "registry.json"
  DefaultProfileId = "default"
  DefaultProfileName = "Default"
  MaxProfileIdLen = 64
  MaxProfileNameLen = 64
  ## Store names as opened by `openDatabase`. Kept in step with
  ## storage/database.nim by hand; a new store added there belongs here
  ## too, or a legacy install would leave it behind in the shared root on
  ## migration.
  LegacyStoreNames = ["settings", "bookmarks", "passwords", "history",
                      "sessions", "feeds", "downloads"]

var
  activeProfile = ""
  registryCache = newJNull()

proc validProfileId*(id: string): bool =
  ## Ids become path components, so the charset is exactly what cannot
  ## escape the profiles directory: ASCII letters, digits, `-` and `_`,
  ## 1 to 64 long. Anything else is refused before it ever reaches the
  ## filesystem.
  if id.len == 0 or id.len > MaxProfileIdLen:
    return false
  for c in id:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      return false
  true

proc validProfileName*(name: string): bool =
  ## Display names are free-form but bounded: non-blank after stripping,
  ## at most 64 characters.
  let trimmed = name.strip()
  trimmed.len > 0 and name.len <= MaxProfileNameLen

proc profilesRoot*(): string =
  ## The directory holding every profile plus the registry. `Profiles/`
  ## sits beside nothing now: a legacy single-store install keeps its seven
  ## store directories at the root until the migration below moves them.
  defaultRoot() / ProfilesDirName

proc profileDir*(id: string): string =
  ## The store root for one profile. Callers validate the id first; this
  ## proc is pure path arithmetic.
  profilesRoot() / id

proc activeProfileId*(): string =
  ## The profile the next store call serves. "" means no caller bound one
  ## yet in this process.
  activeProfile

proc setActiveProfile*(id: string) =
  ## Selects without touching the registry. The service calls this (via
  ## `bc_profile_activate`) before every job; the registry write belongs to
  ## the explicit bind, not to every keystroke.
  activeProfile = id

proc registryPath(): string =
  profilesRoot() / RegistryFileName

proc blankRegistry(): JsonNode =
  %*{"profiles": []}

proc profilesArray(doc: JsonNode): JsonNode =
  ## The registry's profile list, creating it when a hand-edited registry
  ## lost the key. A JsonNode is a reference, so appends through the
  ## result land in `doc`.
  let existing = doc.getOrDefault("profiles")
  if existing.isNil or existing.kind != JArray:
    result = newJArray()
    doc["profiles"] = result
  else:
    result = existing

proc findProfile(doc: JsonNode, id: string): JsonNode =
  ## The registry entry for `id`, or nil when absent. A corrupt entry shape
  ## (missing fields) reads as absent: the registry is rewritten on the
  ## next mutation either way.
  if doc.isNil or doc.kind != JObject:
    return nil
  let profiles = doc.getOrDefault("profiles")
  if profiles.isNil or profiles.kind != JArray:
    return nil
  for entry in profiles.getElems:
    if entry.kind == JObject and entry.getOrDefault("id").getStr("") == id:
      return entry
  nil

proc saveRegistry(doc: JsonNode): int32 =
  ## Persists the registry and refreshes the cache. File errors surface as
  ## `ErrStorage`: a registry that cannot be written cannot be trusted.
  let status = catchingStore("write profile registry"):
    createDir(profilesRoot())
    writeFile(registryPath(), $doc)
    Ok
  if status != Ok:
    return status
  registryCache = doc
  Ok

proc nowUnix(): int64 =
  getTime().toUnix

proc legacyEntries(root: string): seq[string] =
  ## Full paths at the root belonging to the pre-profiles layout: a store
  ## directory itself (`bookmarks/`, `passwords/`), or any file starting
  ## with `<store>.` (the `.db`, `.lock`, `.wal` triples boogie writes
  ## beside the path it was given). Never `Profiles/` or the registry
  ## itself, and never a previous migration's `.bak-` renames, which must
  ## sit still once written.
  result = @[]
  for kind, path in walkDir(root):
    let base = lastPathPart(path)
    if base == ProfilesDirName or base == RegistryFileName:
      continue
    if ".bak-" in base:
      continue
    for name in LegacyStoreNames:
      if base == name or base.startsWith(name & "."):
        result.add(path)
        break

proc migrateLegacy(doc: JsonNode): JsonNode =
  ## Moves a pre-profiles install into `Profiles/default/`: every legacy
  ## entry is renamed into place, so the user's data follows without a
  ## copy, and the registry gains its first entry. A fresh install (no
  ## legacy entries) just gets the entry. Renames are atomic within a
  ## volume, and the stores live on one volume by construction.
  ##
  ## When the destination already holds an entry of the same name — a
  ## half-migrated run, or a fresh profile created before the move — the
  ## occupant is renamed aside to `<name>.bak-<timestamp>`, never deleted.
  ## The legacy tree is always the user's real data (nothing writes the
  ## legacy paths after migration exists); the occupant is at most a fresh
  ## placeholder. Both survive; the real data wins the live path.
  result = doc
  let entries = legacyEntries(defaultRoot())
  if entries.len > 0:
    # Renaming into a sibling needs the parent to exist; the stores
    # themselves create the rest on open.
    createDir(profileDir(DefaultProfileId))
    for src in entries:
      let dest = profileDir(DefaultProfileId) / lastPathPart(src)
      if fileExists(dest) or dirExists(dest):
        let backup = dest & ".bak-" & $nowUnix()
        if dirExists(dest):
          moveDir(dest, backup)
        else:
          moveFile(dest, backup)
      if dirExists(src):
        moveDir(src, dest)
      else:
        moveFile(src, dest)
  if entries.len > 0 or findProfile(result, DefaultProfileId).isNil:
    let stamp = nowUnix()
    # `result` may be a blank registry or one that lost its default entry;
    # either way the default goes first so MRU ties resolve to it.
    var profiles = newJArray()
    profiles.add(%*{
      "id": DefaultProfileId,
      "name": DefaultProfileName,
      "createdAt": stamp,
      "lastUsedAt": stamp,
    })
    for entry in profilesArray(result).getElems:
      if entry.getOrDefault("id").getStr("") != DefaultProfileId:
        profiles.add(entry)
    result["profiles"] = profiles

proc needsMigration(doc: JsonNode): bool =
  ## True for a fresh install, a legacy single-store layout, or a profiles
  ## directory without bookkeeping — and whenever legacy entries still
  ## linger at the root, so a half-migrated install heals itself on the
  ## next launch. Every case is repaired by guaranteeing the default entry
  ## (moving legacy entries when present).
  not dirExists(profilesRoot()) or
    (findProfile(doc, DefaultProfileId).isNil and not fileExists(registryPath())) or
    legacyEntries(defaultRoot()).len > 0

proc ensureRegistry*(): tuple[doc: JsonNode, status: int32] =
  ## Loads the registry into the cache, migrating a legacy install or
  ## creating a fresh default on the way. Idempotent: the file is read at
  ## most once per process, everything after serves the cache.
  if not registryCache.isNil and registryCache.kind == JObject:
    return (registryCache, Ok)
  var doc = blankRegistry()
  if fileExists(registryPath()):
    let status = catchingStore("read profile registry"):
      doc = parseJson(readFile(registryPath()))
      if doc.isNil or doc.kind != JObject:
        raise newException(ValueError, "profile registry is not an object")
      Ok
    if status != Ok:
      return (blankRegistry(), status)
  if needsMigration(doc):
    # Filesystem work (create, rename, write) that must not fault through
    # the C boundary: any IO failure becomes a status, not a crash.
    let status = catchingStore("migrate to profiles"):
      doc = migrateLegacy(doc)
      Ok
    if status != Ok:
      return (blankRegistry(), status)
    let saveStatus = saveRegistry(doc)
    if saveStatus != Ok:
      return (blankRegistry(), saveStatus)
    return (doc, Ok)
  registryCache = doc
  (doc, Ok)

proc resetRegistryCacheForTesting*() =
  ## Drops the in-memory registry so the next call re-reads (and
  ## re-migrates) from disk. Test-only: production code paths never call
  ## this, and the worst a stray call costs is one file read.
  registryCache = newJNull()

proc mostRecentlyUsed(doc: JsonNode): string =
  ## The id with the newest `lastUsedAt`, default-first on ties. "" when
  ## the registry is empty, which only a failed migration leaves behind.
  var best = ""
  var bestUsed = -1'i64
  for entry in profilesArray(doc).getElems:
    if entry.kind != JObject:
      continue
    let used = int64(entry.getOrDefault("lastUsedAt").getInt(-1))
    if used >= bestUsed and entry.getOrDefault("id").getStr("").len > 0:
      bestUsed = used
      best = entry.getOrDefault("id").getStr("")
  best

proc resolveDefaultProfile*(): string =
  ## The most recently used profile, ensuring the registry first. "" when
  ## none can be resolved. This is the unbound-caller fallback in
  ## `ensureOpen`, not something bound callers ever hit.
  let (doc, status) = ensureRegistry()
  if status != Ok:
    return ""
  mostRecentlyUsed(doc)

proc touchProfile(doc: JsonNode, id: string): JsonNode =
  ## Bumps `lastUsedAt` on one entry. Returns the same document for
  ## chaining; the caller saves.
  result = doc
  let entry = findProfile(result, id)
  if not entry.isNil:
    entry["lastUsedAt"] = %nowUnix()

proc activateProfileId(id: string): int32 =
  ## Validates `id` against the cached registry and selects it, without
  ## any registry write. Unknown ids fail closed: a window whose profile
  ## was deleted must error, never silently serve another profile's data.
  if id.len == 0:
    setError("profile id is required")
    return ErrBadInput
  if not validProfileId(id):
    setError("profile id may only use letters, digits, - and _")
    return ErrBadInput
  let (doc, status) = ensureRegistry()
  if status != Ok:
    return status
  if findProfile(doc, id).isNil:
    setError("no such browser profile")
    # Fail closed AND clear: the caller was serving this id (per-job
    # activation) or trying to bind it. Leaving a stale selection would
    # serve a deleted profile's successor state; clearing drops to the
    # unbound fallback (most recently used live profile) instead.
    activeProfile = ""
    return ErrNotFound
  setActiveProfile(id)
  Ok

proc profileUse*(id: cstring): int32 {.exportc: "bc_profile_use".} =
  ## Binds this process to one profile for subsequent store calls and
  ## records the use. Called once per service connection (and in tests),
  ## not per call — per-call selection is `bc_profile_activate`, which
  ## skips the registry write.
  if id.isNil:
    setError("profile id is required")
    return ErrBadInput
  let status = activateProfileId($id)
  if status != Ok:
    return status
  let (doc, ensureStatus) = ensureRegistry()
  if ensureStatus != Ok:
    return ensureStatus
  saveRegistry(touchProfile(doc, $id))

proc profileActivate*(id: cstring): int32 {.exportc: "bc_profile_activate".} =
  ## Selects the active profile without a registry write: the per-job half
  ## of the binding. NULL or empty selects nothing and succeeds, leaving
  ## the unbound fallback (most recently used) in place.
  if id.isNil or ($id).len == 0:
    return Ok
  activateProfileId($id)

proc profilesEnsure*(buffer: ptr char, capacity: int32,
    needed: ptr int32): int32 {.exportc: "bc_profiles_ensure".} =
  ## Migrates a legacy install when needed and returns the registry as
  ## `{"profiles": [{id, name, createdAt, lastUsedAt}]}`. The app calls
  ## this once at startup, before listing or binding.
  let (doc, status) = ensureRegistry()
  if status != Ok:
    return status
  emitJson(doc, buffer, capacity, needed)

proc profilesList*(buffer: ptr char, capacity: int32,
    needed: ptr int32): int32 {.exportc: "bc_profiles_list".} =
  ## The registry, same shape as `bc_profiles_ensure`. Listing ensures
  ## first, so it also migrates.
  let (doc, status) = ensureRegistry()
  if status != Ok:
    return status
  emitJson(doc, buffer, capacity, needed)

proc profilesCreate*(id: cstring, name: cstring): int32 {.exportc: "bc_profiles_create".} =
  ## Adds a profile: validates, creates its directory, appends the
  ## registry entry. The id is caller-chosen (a UUID in the app) and
  ## permanent — renames change the name, never the directory.
  if id.isNil or name.isNil:
    setError("profile id and name are required")
    return ErrBadInput
  let profileId = $id
  if not validProfileId(profileId):
    setError("profile id may only use letters, digits, - and _")
    return ErrBadInput
  if not validProfileName($name):
    setError("profile name must be non-blank and at most 64 characters")
    return ErrBadInput
  let (doc, status) = ensureRegistry()
  if status != Ok:
    return status
  if not findProfile(doc, profileId).isNil:
    setError("a browser profile with that id already exists")
    return ErrBadInput
  let dirStatus = catchingStore("create profile directory"):
    createDir(profileDir(profileId))
    Ok
  if dirStatus != Ok:
    return dirStatus
  var profiles = profilesArray(doc)
  let stamp = nowUnix()
  profiles.add(%*{
    "id": profileId,
    "name": ($name).strip(),
    "createdAt": stamp,
    "lastUsedAt": stamp,
  })
  saveRegistry(doc)

proc profilesRename*(id: cstring, name: cstring): int32 {.exportc: "bc_profiles_rename".} =
  ## Renames the display name. The directory (and every store in it) is
  ## untouched: renames never move data.
  if id.isNil or name.isNil:
    setError("profile id and name are required")
    return ErrBadInput
  if not validProfileName($name):
    setError("profile name must be non-blank and at most 64 characters")
    return ErrBadInput
  let (doc, status) = ensureRegistry()
  if status != Ok:
    return status
  let entry = findProfile(doc, $id)
  if entry.isNil:
    setError("no such browser profile")
    return ErrNotFound
  entry["name"] = %($name).strip()
  saveRegistry(doc)

proc removeProfileFromRegistry*(id: string): int32 =
  ## Drops `id` from the registry and saves. Refuses the last profile:
  ## the store layer always needs somewhere to serve from, and deleting
  ## the final profile is a reset, not a deletion. Clears the active
  ## selection when it points at the removed profile.
  let (doc, status) = ensureRegistry()
  if status != Ok:
    return status
  if findProfile(doc, id).isNil:
    setError("no such browser profile")
    return ErrNotFound
  if profilesArray(doc).len <= 1:
    setError("the last browser profile cannot be deleted")
    return ErrBadInput
  var kept = newJArray()
  for entry in profilesArray(doc).getElems:
    if entry.getOrDefault("id").getStr("") != id:
      kept.add(entry)
  doc["profiles"] = kept
  if activeProfile == id:
    activeProfile = ""
  saveRegistry(doc)
