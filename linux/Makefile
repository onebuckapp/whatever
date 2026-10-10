NIM_FLAGS := --threads:on --mm:arc --path:src
CORE_SRC := $(CURDIR)/../core/nim-core
BUILD := $(CURDIR)/build
SHELL_BIN := $(BUILD)/whatever
HELPER_BIN := $(BUILD)/whatever-store

.PHONY: all build shell helper run run-helper clean check

all: build

build: shell helper

shell:
	mkdir -p "$(BUILD)"
	clue build src/shell/main.nim --release $(NIM_FLAGS) \
		--out:$(SHELL_BIN)

helper:
	mkdir -p "$(BUILD)"
	clue build src/helper/store_service.nim --release $(NIM_FLAGS) \
		--path:$(CORE_SRC) --out:$(HELPER_BIN)

run: shell
	"$(SHELL_BIN)"

run-helper: helper
	"$(HELPER_BIN)"

check:
	clue check src/shell/main.nim $(NIM_FLAGS)
	clue check src/shell/store_client.nim $(NIM_FLAGS)
	clue check src/helper/store_service.nim $(NIM_FLAGS) --path:$(CORE_SRC)

clean:
	rm -rf build nimcache src/nimcache
