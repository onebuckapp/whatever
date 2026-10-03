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

.PHONY: generate build run clean core test-core check-abi

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

run: build
	open "$(APP)"

clean:
	rm -rf Build $(PROJECT)
	$(MAKE) -C "$(CORE_DIR)" clean
