.PHONY: all core macos macos_release run test check-abi check-tr linux linux-run clean

all: macos

core:
	$(MAKE) -C core build

test:
	$(MAKE) -C core test

check-abi:
	$(MAKE) -C core check-abi

# Every tr()/LocaleItem() literal exists in locale/en.po. The checker is a
# stdlib-only Nim tool, so this needs a Nim toolchain but no clue install
# and no dependencies; the root defaults to this checkout.
check-tr:
	nim r core/nim-core/tools/check_tr.nim

macos: core
	$(MAKE) -C macos build

macos_release: core
	$(MAKE) -C macos release

run:
	$(MAKE) -C macos run

linux: core
	$(MAKE) -C linux build

linux-run: core
	$(MAKE) -C linux run

clean:
	$(MAKE) -C macos clean