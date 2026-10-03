# browsercore — Nim side of the Whatever backend.
#
# Builds to a macOS static library (`libbrowsercore.a`) that Swift links
# directly and calls through the C ABI declared in
# `../include/browsercore.h`.
#
# Every export is documented there with its ownership, threading and
# error contract. The rule for the whole surface: Nim writes into memory
# Swift owns, so nothing crosses the boundary that Swift must free.

import ./api/qr_api

export qr_api

proc bcInit*() {.exportc: "bc_init".} =
  ## Registers the calling thread with Nim's runtime and forces module
  ## initialization. Idempotent; Swift calls it once at launch.
  when compileOption("threads"):
    setupForeignThreadGc()