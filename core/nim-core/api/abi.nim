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

# abi — shared result codes, error reporting, and buffer conventions for the
# C ABI.
#
# Ownership rules (unchanged from the QR surface):
#   * Nim never hands allocated memory to Swift for it to guess at. Variable
#     length results use a two-phase protocol: call with a NULL or undersized
#     buffer to learn the required size, then call again with an exactly sized
#     buffer that Swift owns.
#   * `bcLastError` copies into a caller-owned buffer, so there is no
#     cross-boundary free to get wrong.
#
# Threading: the exports share module-level state (the error string and the
# database handles), so one caller thread at a time is required. Inside the XPC
# service that means one queue; storage/database.nim explains why the stores
# themselves are still opened concurrent.
#
# Sync: every call is synchronous. The service hops onto its own queue before
# calling in, so the app's main thread never waits on disk.

import std/[json, strutils]
import openparser/json

const
  Ok* = 0'i32
  ErrBadInput* = 1'i32
  ErrBufferTooSmall* = 2'i32
  ErrStorage* = 3'i32
  ErrEncoder* = 4'i32
  ErrNotFound* = 5'i32
  ErrLocked* = 6'i32
  ## The payload does not fit the symbol at any error-correction level. Kept
  ## out of the low ordinals so it cannot be confused with the codes above: the
  ## QR surface and the store surface share one set of codes precisely because
  ## they share one caller, and a private code per module is how that goes
  ## wrong. This one is genuinely QR's own, and it sits above the shared range
  ## rather than inside it.
  ErrPayloadTooLong* = 7'i32

var lastErrorMessage = ""

proc setError*(message: string) =
  lastErrorMessage = message

proc clearError*() =
  lastErrorMessage.setLen(0)

proc lastError*(buffer: ptr char, capacity: int32): int32 {.exportc: "bc_last_error".} =
  ## Copies the last error message into the caller-owned `buffer` as a
  ## NUL-terminated UTF-8 string, truncating when it does not fit, and returns
  ## the full message length so a caller can detect truncation. Passing NULL for
  ## `buffer` only queries the length.
  ##
  ## One slot for the whole ABI: every module's failures land here, so the
  ## caller does not have to know which module raised.
  ##
  ## The terminator is always written, including for an empty message, and the
  ## message is never indexed past its own length. Copying `message.len + 1`
  ## bytes from `message[0]` looks right but is not: with `message.len == 0`
  ## there is no byte 0, so the copy reads whatever happens to sit at the
  ## string's data pointer — and since a cleared message reuses the buffer of
  ## whatever was there before, that byte is the old message's first character.
  ## The caller then gets a buffer with no terminator in it and reads off the
  ## end looking for one.
  let message = lastErrorMessage
  let required = int32(message.len + 1)
  if buffer.isNil or capacity <= 0:
    return required
  let copied = if capacity >= required: message.len else: max(0, int(capacity) - 1)
  if copied > 0:
    copyMem(buffer, message[0].addr, copied)
  cast[ptr UncheckedArray[char]](buffer)[copied] = '\0'
  required

proc writeBuffer*(payload: string, buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
  ## Copies a NUL-terminated `payload` into a caller-owned buffer and reports
  ## its full length including the terminator through `needed`, which may be
  ## NULL.
  ##
  ## Two-phase by contract: with a NULL buffer, or a capacity below what the
  ## payload needs, nothing is written and `ErrBufferTooSmall` comes back so
  ## the caller can size an exact buffer and call again.
  let required = int32(payload.len + 1)
  if not needed.isNil:
    needed[] = required
  if buffer.isNil or capacity < required:
    return ErrBufferTooSmall
  ## `payload` is a JSON document in every current caller, so it is never empty,
  ## but copying `len + 1` bytes from `payload[0]` on a zero-length string would
  ## read one byte out of bounds and leave the terminator undefined. Same reason
  ## `bc_last_error` writes its terminator explicitly.
  if payload.len > 0:
    copyMem(buffer, payload[0].addr, payload.len)
  cast[ptr UncheckedArray[char]](buffer)[payload.len] = '\0'
  Ok

proc emitJson*(document: JsonNode, buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
  ## Serializes `document` and hands it to the two-phase buffer protocol.
  writeBuffer($document, buffer, capacity, needed)

## Guards against a store faulting out through the C boundary, turning a Nim
## exception into a status code plus a message.
template catchingStore*(context: string, body: untyped): untyped =
  try:
    body
  except CatchableError as error:
    lastErrorMessage = context & ": " & error.msg
    ## A held file lock is the one storage failure worth distinguishing: it
    ## means another process already owns the store, and retrying is
    ## reasonable where a corrupt database is not.
    if error.msg.toLowerAscii().contains("lock"):
      ErrLocked
    else:
      ErrStorage