.PHONY: all core macos run test check-abi clean

all: macos

core:
	$(MAKE) -C core build

test:
	$(MAKE) -C core test

check-abi:
	$(MAKE) -C core check-abi

macos: core
	$(MAKE) -C macos build

run:
	$(MAKE) -C macos run

clean:
	$(MAKE) -C macos clean