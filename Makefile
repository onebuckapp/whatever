.PHONY: all core macos macos_release run test check-abi linux linux-run clean

all: macos

core:
	$(MAKE) -C core build

test:
	$(MAKE) -C core test

check-abi:
	$(MAKE) -C core check-abi

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