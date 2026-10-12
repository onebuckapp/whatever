PROJECT := Whatever.xcodeproj
SCHEME := Whatever
CONFIG ?= Debug
DERIVED_DATA := $(CURDIR)/Build
APP := $(DERIVED_DATA)/Build/Products/$(CONFIG)/Whatever.app
XCODEGEN := $(shell command -v xcodegen || echo /usr/local/bin/xcodegen)

# Nim backend from core/, linked in as libbrowsercore.a.
CORE_DIR := $(CURDIR)/../core
CORE_LIB := $(CORE_DIR)/build/libbrowsercore.a
CORE_SOURCES := $(shell find $(CORE_DIR)/nim-core -name '*.nim' 2>/dev/null)
# Compiled gettext catalogs, built by `make -C core` from locale/*.po.
LOCALE_DIR := $(CURDIR)/../locale
LOCALE_DEST := $(APP)/Contents/Resources/locale

.PHONY: generate build release run run-release clean core test-core check-abi

generate:
	$(XCODEGEN) generate

core:
	$(MAKE) -C "$(CORE_DIR)" build

test-core:
	$(MAKE) -C "$(CORE_DIR)" test

check-abi:
	$(MAKE) -C "$(CORE_DIR)" check-abi

$(CORE_LIB): $(CORE_SOURCES)
	$(MAKE) -C "$(CORE_DIR)" build

build: generate $(CORE_LIB)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath "$(DERIVED_DATA)" build
	@for mo in $(LOCALE_DIR)/*/LC_MESSAGES/whatever.mo; do \
		[ -e "$$mo" ] || continue; \
		lang=$$(basename $$(dirname $$(dirname "$$mo"))); \
		mkdir -p "$(LOCALE_DEST)/$$lang/LC_MESSAGES"; \
		cp "$$mo" "$(LOCALE_DEST)/$$lang/LC_MESSAGES/whatever.mo"; \
	done

# The optimised configuration, alongside Debug rather than instead of it: both
# products live under the same derived data path and neither build dirties the
# other. `CONFIG` is a variable, so `make build CONFIG=Release` is equivalent; this
# is the short form.
#
# Recursive rather than a target-specific `release: CONFIG=Release`, because a
# command-line variable propagates into the sub-make and target-specific variables
# would resolve $(APP) too late for anything that opens the result.
release:
	$(MAKE) build CONFIG=Release

run: build
	open "$(APP)"

run-release:
	$(MAKE) run CONFIG=Release

clean:
	rm -rf Build $(PROJECT)
	$(MAKE) -C "$(CORE_DIR)" clean
