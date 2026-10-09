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

# browsercore — Nim side of the Whatever backend.
#
# Builds to a macOS static library (`libbrowsercore.a`). The XPC service links
# it and calls through the C ABI declared in `../include/browsercore.h`; the
# app process never links it.
#
# Every export is documented in that header with its ownership, threading and
# error contract. The rules for the whole surface:
#
#   * Nim writes into memory the caller owns, so nothing crosses the boundary
#     that the caller would have to free.
#   * Variable-length results use a two-phase protocol: call with a NULL
#     buffer to learn the size, then again with an exactly sized one.
#   * Fallible calls return a status ordinal; `bc_last_error` carries the
#     message.
#
# The store layer owns the persistent state; see storage/database.nim for why
# it is the only thing that opens a database, and why crash handlers are
# compiled out. Because those handlers are gone, this module also owns
# releasing the stores before the process goes away.

import ./api/qr_api
import ./api/settings_api
import ./api/bookmark_api
import ./api/password_api
import ./api/history_api
import ./api/session_api
import ./api/feed_api
import ./api/filter_api
import ./api/find_api
import ./api/downloads_api

export qr_api
export settings_api
export bookmark_api
export password_api
export history_api
export session_api
export feed_api
export filter_api
export find_api
export downloads_api

var threadRegistered {.threadvar.}: bool

proc registerThread() =
  ## Makes the calling thread usable by the allocator.
  ##
  ## `setupForeignThreadGc` is what creates the allocator's per-thread state, and
  ## it only ever has to run once per thread. `threadRegistered` is a Nim
  ## threadvar, which compiles to a C thread-local, so reading it here is safe
  ## on a thread that has not been set up yet: no allocation happens before the
  ## registration.
  when compileOption("threads"):
    if not threadRegistered:
      setupForeignThreadGc()
      threadRegistered = true

proc bcInit*() {.exportc: "bc_init".} =
  ## Registers the calling thread with Nim's runtime and forces module
  ## initialization.
  ##
  ## Idempotent. The XPC service calls it once at launch, before the listener
  ## exists, which covers the main thread.
  registerThread()

proc bcRegisterThread*() {.exportc: "bc_register_thread".} =
  ## Registers the calling thread with Nim's runtime, if it is not already.
  ##
  ## Nim keeps its allocator's per-thread state in thread-local storage that
  ## only a registered thread has. An export reached from an unregistered thread
  ## does not return an error: it faults inside `rawAlloc` (EXC_BAD_ACCESS at a
  ## small offset from nil) and takes the process down.
  ##
  ## A GCD queue does not promise to run every block on the same thread, so a
  ## service cannot simply register the thread it started on and assume the rest.
  ## Call this before the first core call on any thread; it is a thread-local
  ## read on every call after the first, so it is cheap enough to leave in.
  registerThread()

proc bcShutdown*() {.exportc: "bc_shutdown".} =
  ## Flushes and closes the stores, releasing boogie's lock on the store path.
  ##
  ## Idempotent, and a no-op if nothing has been opened yet. Every export is
  ## still callable afterwards: the next one reopens the stores.
  shutdownStores()