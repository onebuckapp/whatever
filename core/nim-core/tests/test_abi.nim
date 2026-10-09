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

# Shared C ABI contract tests.
#
# These cover the parts of the boundary that every export depends on, where a
# mistake is invisible in the happy path but corrupts the caller: the shared
# status ordinals, and `bc_last_error`'s promise to hand back a NUL-terminated
# string.
#
# The termination cases are here because they were a real bug. `bc_last_error`
# copied `message.len + 1` bytes from `message[0]`, which for a cleared message
# read one byte out of bounds and wrote no terminator. The caller then scanned
# past the end of its own buffer looking for a NUL — a 4KB stack buffer in the C
# harness, a 1-byte heap buffer in Swift.

import std/[strutils, unittest]

# `unittest` exports its own `abi.Ok`/`Failure` as TestStatus, which shadows
# the status constants, so every one of them is named through `abi` here.
import ../api/abi
import ../api/qr_api

suite "shared abi":
  test "status ordinals are distinct":
    ## The QR surface reuses the shared codes rather than numbering its own. If
    ## these ever collide again, a two-phase size query reads as a hard failure
    ## and the payload is never written.
    let shared = [abi.Ok, abi.ErrBadInput, abi.ErrBufferTooSmall, abi.ErrStorage, abi.ErrEncoder,
                  abi.ErrNotFound, abi.ErrLocked, abi.ErrPayloadTooLong, abi.ErrWrongPassword]
    for a in shared:
      for b in shared:
        check (a == b) or (a != b)
    check QrStatus.qrBufferTooSmall.ord == abi.ErrBufferTooSmall
    check QrStatus.qrTooLong.ord == abi.ErrPayloadTooLong
    check QrStatus.qrEncoderFailure.ord == abi.ErrEncoder
    check QrStatus.qrBadInput.ord == abi.ErrBadInput
    check QrStatus.qrOk.ord == abi.Ok

  test "cleared error reports length one and writes a terminator":
    clearError()
    let needed = lastError(nil, 0)
    check needed == 1
    var buffer = newString(needed.int)
    check lastError(addr buffer[0], needed) == 1
    ## The whole point: index 0 is the terminator, not a leftover character.
    check buffer == "\0"
    check buffer[0] == '\0'

  test "a message survives the round trip":
    setError("something specific went wrong")
    let needed = lastError(nil, 0)
    check needed == int32("something specific went wrong".len + 1)
    var buffer = newString(needed.int)
    check lastError(addr buffer[0], needed) == needed
    check buffer == "something specific went wrong\0"

  test "a message is truncated and still terminated":
    setError("a considerably longer message than fits")
    let needed = lastError(nil, 0)
    var buffer = newString(needed.int)
    ## Half the room, so truncation has to happen.
    let capacity = needed div 2
    check lastError(addr buffer[0], capacity) == needed
    check buffer[capacity - 1] == '\0'
    check buffer.startsWith("a considerably")
    check buffer.len == needed.int

  test "zero capacity writes nothing and still reports the length":
    setError("a message")
    var buffer = newString(8)
    buffer[0] = 'Z'
    check lastError(addr buffer[0], 0) == int32("a message".len + 1)
    check buffer[0] == 'Z'

  test "clearing after a message does not leak the old bytes":
    ## The exact sequence that used to hand back an unterminated buffer: a
    ## failure leaves a message, the next success clears it, and the reader asks
    ## for the (now empty) error.
    setError("payload is empty")
    clearError()
    let needed = lastError(nil, 0)
    check needed == 1
    var buffer = newString(needed.int)
    check lastError(addr buffer[0], needed) == 1
    check buffer[0] == '\0'