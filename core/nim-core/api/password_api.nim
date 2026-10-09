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

# password_api — password vault C ABI.
#
# The vault is one encrypted JSON document in the `passwords` docstore under
# the fixed key "vault". The core owns the whole vault engine: Argon2id key
# derivation and XChaCha20-Poly1305 authenticated encryption come from
# nimcypher (leaf modules only, never the umbrella — same rule as qr_api's
# openparser import), strength scoring from blackpaper, and the session key
# lives in this module while unlocked. Swift never implements crypto.
#
# Envelope on disk:
#   {"version":1,
#    "kdf":{"algorithm":"argon2id","salt":hex},
#    "sealed":{"nonce":hex24,"ciphertext":base64,"mac":hex16}}
#
# Session model: `setup` and `unlock` derive the key (Argon2id, nimcypher's
# interactive profile) and keep it plus the decrypted vault in memory;
# `lock` wipes both. Every save re-seals with a fresh random nonce: a nonce
# is never reused with one key, so identical vaults still differ on disk.
# The master password is enforced at 8+ characters here, not just in the
# UI, so no caller can create a weaker vault.
#
# Hygiene: password copies and the plaintext are wiped (`wipeString`) on
# every path that no longer needs them; the key itself is a `Secret` and is
# wiped automatically when it goes out of scope. The boundary copies are
# unavoidable — Swift holds the same bytes — but nothing lingers past its use.
#
# Ownership, threading and sync: see api/abi.nim. The session state below is
# module-level, so like every other export this is one caller thread at a
# time. Unlock and setup run Argon2id (milliseconds, not the microseconds of
# the other exports); they are still synchronous user actions, so that is
# where the cost belongs.

import std/[base64, options]
import openparser/json
import boogie/stores/docstore
import nimcypher/password
import nimcypher/encrypt
import nimcypher/utils
import nimcypher/secret
import blackpaper
import ../storage/database
import ./abi
import ./settings_api
import ./password_common

const
  ## The vault document's fixed key. There is exactly one document: the
  ## vault is written whole, never per site.
  VaultDocKey = "vault"
  VaultEnvelopeVersion = 1
  EmptyVault = """{"sites": []}"""
  MinMasterPasswordLen = 8

var
  ## Derived key, valid only while unlocked. A `Secret` wipes itself when it
  ## goes out of scope, including on reassignment.
  vaultSessionKey: Secret[Key32]
  ## Salt the session key was derived with; needed to re-seal on save.
  vaultSessionSalt: RandomBytes
  vaultSessionOpen = false
  ## Decrypted vault JSON while unlocked.
  vaultSessionText = ""

proc wipeString(s: var string) =
  ## Best-effort scrub of a password or plaintext copy. The allocator may
  ## keep the pages, but the bytes are gone.
  for i in 0 ..< s.len:
    s[i] = '\x00'
  s.setLen(0)

proc lockVault() =
  ## Wipes the session key and plaintext. Idempotent: locking twice, or
  ## locking without ever unlocking, is a no-op rather than an error.
  if vaultSessionOpen:
    wipeSecret(vaultSessionKey)
    vaultSessionOpen = false
  wipeString(vaultSessionText)
  vaultSessionSalt = default(RandomBytes)

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc sealForStore(plain: string, key: Key32, salt: RandomBytes, hint: string): JsonNode =
  ## Encrypts `plain` under a fresh random nonce and wraps it in the
  ## envelope. A fresh nonce per save is what keeps equal vaults unequal.
  let nonce = randomBytes[24]()
  let (cipher, mac) = encrypt(toBytes(plain), key, nonce)
  result = %*{
    "version": VaultEnvelopeVersion,
    "kdf": {"algorithm": "argon2id", "salt": toHex(salt)},
    "sealed": {
      "nonce": toHex(nonce),
      "ciphertext": base64.encode(bytesToString(cipher)),
      "mac": toHex(mac)
    }
  }
  # The hint is plaintext outside the seal by necessity: it must be readable
  # while locked, which is exactly when the key is unavailable.
  if hint.len > 0:
    result["hint"] = %hint

type
  VaultParts = tuple[salt: RandomBytes, nonce: Nonce24, cipher: seq[byte], mac: Mac16]

proc openEnvelope(doc: JsonNode): VaultParts =
  ## Parses and validates a stored envelope. Raises `ValueError` on any
  ## shape problem, including an unknown version or KDF.
  try:
    if doc["version"].getInt != VaultEnvelopeVersion:
      raise newException(ValueError, "unsupported vault version")
    let kdf = doc["kdf"]
    if kdf["algorithm"].getStr != "argon2id":
      raise newException(ValueError, "unsupported vault KDF")
    let sealed = doc["sealed"]
    result.salt = fromHex[16, uint8](kdf["salt"].getStr)
    result.nonce = fromHex[24, uint8](sealed["nonce"].getStr)
    result.cipher = toBytes(base64.decode(sealed["ciphertext"].getStr))
    result.mac = fromHex[16, uint8](sealed["mac"].getStr)
  except KeyError, ValueError:
    raise newException(ValueError, "damaged vault envelope")

var strengthDict: PasswordStrengthDictionary

proc ensureStrengthDict() =
  ## The common-password dictionary, built once from the embedded list.
  if strengthDict.isNil:
    strengthDict = preparePasswordStrengthDictionary(CommonPasswords)

proc passwordStatus*(buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_password_status".} =
  ## `{"state":"unset"|"locked"|"unlocked"}`. "unset" means no vault document
  ## exists yet; "unlocked" means the session key is in memory.
  var db = storeRef()
  var state = "unset"
  let status = catchingStore("read vault status"):
    var passwords = db.passwords
    if vaultSessionOpen:
      state = "unlocked"
    elif passwords.hasKey(VaultDocKey):
      state = "locked"
    Ok
  if status != Ok: return status
  emitJson(%*{"state": state}, buffer, capacity, needed)

proc passwordSetup*(master: cstring, hint: cstring): int32 {.exportc: "bc_password_setup".} =
  ## Creates the vault with `master` as its password and leaves it unlocked.
  ## `hint` is an optional reminder, stored in plaintext outside the seal so
  ## it can be shown while locked; it must not be the password itself. `hint`
  ## may be NULL for none. `ErrBadInput` for a short password, a hint that
  ## equals the password, or when a vault already exists.
  if master.isNil or ($master).len < MinMasterPasswordLen:
    setError("master password must be at least 8 characters")
    return ErrBadInput
  let hintText = if hint.isNil: "" else: $hint
  if hintText.len > 0 and hintText == $master:
    setError("the hint must not be the password")
    return ErrBadInput
  var db = storeRef()
  let status = catchingStore("create vault"):
    var passwords = db.passwords
    if passwords.hasKey(VaultDocKey):
      setError("a vault already exists")
      return ErrBadInput
    var pw = $master
    let salt = generateSalt()
    let key = deriveKeyFromPassword(pw, salt)
    wipeString(pw)
    passwords.upsert(VaultDocKey, sealForStore(EmptyVault, key.data, salt, hintText))
    vaultSessionKey = key
    vaultSessionSalt = salt
    vaultSessionOpen = true
    vaultSessionText = EmptyVault
    Ok
  status

proc passwordUnlock*(master: cstring): int32 {.exportc: "bc_password_unlock".} =
  ## Derives the session key and opens the vault. A MAC failure means the
  ## password is wrong (or the vault is damaged, which is indistinguishable
  ## and reported the same way); that is `ErrWrongPassword`, not a storage
  ## error, so the UI can answer "wrong password, try again".
  if master.isNil or ($master).len == 0:
    setError("master password is required")
    return ErrBadInput
  var db = storeRef()
  let status = catchingStore("unlock vault"):
    var passwords = db.passwords
    let existing = passwords.get(VaultDocKey)
    if existing.isNone:
      setError("no vault exists yet")
      return ErrNotFound
    let parts = openEnvelope(existing.get)
    var pw = $master
    let key = deriveKeyFromPassword(pw, parts.salt)
    wipeString(pw)
    var plain = ""
    try:
      plain = toString(decrypt(parts.cipher, parts.mac, key.data, parts.nonce))
    except ValueError:
      setError("wrong master password or a damaged vault")
      return ErrWrongPassword
    vaultSessionKey = key
    vaultSessionSalt = parts.salt
    vaultSessionOpen = true
    vaultSessionText = plain
    plain = ""
    Ok
  status

proc passwordLock*(): int32 {.exportc: "bc_password_lock".} =
  ## Wipes the session key and plaintext. Always succeeds.
  clearError()
  lockVault()
  Ok

proc passwordVaultGet*(buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_password_vault_get".} =
  ## The decrypted vault JSON. `ErrLocked` while the vault is locked: the
  ## caller checks `bc_password_status` first, so reaching here locked is a
  ## programming error, not a state to recover from.
  if not vaultSessionOpen:
    setError("the vault is locked")
    return ErrLocked
  writeBuffer(vaultSessionText, buffer, capacity, needed)

proc readStoredHint(passwords: var DocumentStore): string =
  ## The envelope's plaintext hint, or "" when absent. Never raises: a
  ## missing or misshapen envelope simply has no hint. Storage I/O failures
  ## propagate to the caller's `catchingStore`.
  try:
    let existing = passwords.get(VaultDocKey)
    if existing.isSome:
      return existing.get["hint"].getStr
  except KeyError, ValueError:
    discard
  ""

proc passwordVaultSet*(document: cstring): int32 {.exportc: "bc_password_vault_set".} =
  ## Replaces the vault with `document`, which must be a JSON object, and
  ## re-seals it under a fresh nonce. `ErrLocked` while locked.
  if not vaultSessionOpen:
    setError("the vault is locked")
    return ErrLocked
  if document.isNil:
    setError("vault document is required")
    return ErrBadInput
  let payload = $document
  let parsed = parseJson(payload)
  if parsed.kind != JObject:
    setError("vault document must be a JSON object")
    return ErrBadInput
  var db = storeRef()
  let status = catchingStore("write vault"):
    var passwords = db.passwords
    let hint = readStoredHint(passwords)
    passwords.upsert(VaultDocKey, sealForStore(payload, vaultSessionKey.data, vaultSessionSalt, hint))
    vaultSessionText = payload
    Ok
  status

proc passwordVaultDelete*(): int32 {.exportc: "bc_password_vault_delete".} =
  ## Removes the vault document and locks, returning to fresh-install state.
  ## Deliberately unauthenticated, like "remove all" everywhere else: store
  ## access already implies the user.
  var db = storeRef()
  let status = catchingStore("delete vault"):
    var passwords = db.passwords
    discard passwords.delete(VaultDocKey)
    Ok
  lockVault()
  status

proc passwordHintGet*(buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_password_hint_get".} =
  ## `{"hint": "..."}` — "" when none was kept. Readable while locked: the
  ## hint is plaintext outside the seal by necessity. `ErrNotFound` when no
  ## vault exists yet.
  var db = storeRef()
  var hint = ""
  let status = catchingStore("read vault hint"):
    var passwords = db.passwords
    let existing = passwords.get(VaultDocKey)
    if existing.isNone:
      setError("no vault exists yet")
      return ErrNotFound
    hint = readStoredHint(passwords)
    Ok
  if status != Ok: return status
  emitJson(%*{"hint": hint}, buffer, capacity, needed)

proc passwordHintSet*(hint: cstring): int32 {.exportc: "bc_password_hint_set".} =
  ## Replaces the vault's plaintext hint, re-sealing under a fresh nonce.
  ## Requires the vault to be unlocked: a hint writable while locked would
  ## let anyone with store access plant a phishing hint. Empty (or NULL)
  ## clears it. `ErrLocked` while locked.
  if not vaultSessionOpen:
    setError("the vault is locked")
    return ErrLocked
  let hintText = if hint.isNil: "" else: $hint
  var db = storeRef()
  let status = catchingStore("write vault hint"):
    var passwords = db.passwords
    passwords.upsert(
      VaultDocKey,
      sealForStore(vaultSessionText, vaultSessionKey.data, vaultSessionSalt, hintText)
    )
    Ok
  status

proc strengthLabel(reason: PasswordStrengthReason): string =
  case reason
  of TooShort: "tooShort"
  of NotEnoughVariety: "notEnoughVariety"
  of TooPredictable: "tooPredictable"
  of SimilarToCommon: "similarToCommon"
  of GoodComplexity: "goodComplexity"

proc passwordScore*(password: cstring, buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_password_strength".} =
  ## Scores `password` as `{"strength","score","reason"}`: strength is one of
  ## "weak", "medium" or "strong". Never touches the vault or the session, so
  ## it works locked, and an empty password simply scores weak.
  if password.isNil:
    setError("password is required")
    return ErrBadInput
  ensureStrengthDict()
  let res = passwordStrength($password, strengthDict)
  let label =
    case res.strength
    of Weak: "weak"
    of Medium: "medium"
    of Strong: "strong"
  emitJson(
    %*{"strength": label, "score": res.score.float64, "reason": strengthLabel(res.reason)},
    buffer, capacity, needed
  )
