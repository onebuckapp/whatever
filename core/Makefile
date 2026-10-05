NIM_FLAGS := --threads:on --mm:arc -d:boogieNoCrashHandlers
NIM_SRC := nim-core/browsercore.nim
LIB := build/libbrowsercore.a
HEADER := include/browsercore.h
NIM_SOURCES := nim-core/browsercore.nim nim-core/api/abi.nim nim-core/api/qr_api.nim \
	nim-core/api/settings_api.nim nim-core/api/bookmark_api.nim \
	nim-core/api/history_api.nim nim-core/api/session_api.nim \
	nim-core/api/feed_api.nim nim-core/api/filter_api.nim \
	nim-core/api/find_api.nim \
	nim-core/storage/database.nim nim-core/storage/schema.nim
.PHONY: all build test check-abi clean

all: build

build: $(LIB)

# Nim needs no entry point for a static library; every exported proc is
# pulled in on demand by the linker.
#
#   --threads:on --mm:arc  boogie's `enableConcurrency` requires threads, and
#                         ARC is the memory manager chosen for the core. The
#                         tests below build with the same flags, because a
#                         suite that runs under a different memory manager is
#                         not testing what ships.
#   -d:boogieNoCrashHandlers
#                         drops boogie's SIGSEGV/SIGABRT/SIGBUS/SIGILL handlers
#                         (they fight crash reporters) and its SIGTERM
#                         flush-then-terminate, which would turn logout and
#                         XPC idle eviction into non-graceful exits. The core
#                         flushes and checkpoints for itself instead: see
#                         `bc_shutdown` and the `atexit` hook in browsercore.nim.
$(LIB): $(NIM_SOURCES) nim-core/browsercore.nimble
	clue build $(NIM_SRC) --release --app:staticlib \
		$(NIM_FLAGS) --out:$(LIB)

test:
	cd nim-core && clue test $(NIM_FLAGS)

# The header is hand written, so prove it still matches the archive.
check-abi: $(LIB)
	@missing=0; \
	for symbol in $$(nm -gU $(LIB) | awk '$$2 == "T" && $$3 ~ /^_bc_/ { print $$3 }' | sort -u); do \
		grep -q "\b$${symbol#_}[[:space:]]*(" $(HEADER) \
			|| { echo "missing from $(HEADER): $${symbol#_}"; missing=1; }; \
	done; \
	[ $$missing -eq 0 ] && echo "check-abi: header matches $(LIB)"

clean:
	rm -rf build nimcache nim-core/nimcache