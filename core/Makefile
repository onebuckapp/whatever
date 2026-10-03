NIM_SRC := nim-core/browsercore.nim
LIB := build/libbrowsercore.a
HEADER := include/browsercore.h
NIM_SOURCES := nim-core/browsercore.nim nim-core/api/qr_api.nim
.PHONY: all build test check-abi clean

all: build

build: $(LIB)

# Nim needs no entry point for a static library; every exported proc is
# pulled in on demand by the linker.
$(LIB): $(NIM_SOURCES) nim-core/browsercore.nimble
	clue build $(NIM_SRC) --release --app:staticlib --out:$(LIB)

test:
	cd nim-core && clue test

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