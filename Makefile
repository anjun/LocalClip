# LocalClip — macOS menu bar clipboard (local-only)
#
# make release  → universal .app (arm64 + x86_64) + ZIP + DMG
# make package  → host-arch .app only (faster, for dev)
# make test     → unit runner
# make clean    → remove build/dist intermediates

.PHONY: release package test clean install open help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SHELL := /bin/bash

help:
	@echo "LocalClip targets:"
	@echo "  make release  - universal Intel+Apple silicon package (ZIP + DMG)"
	@echo "  make package  - single-arch .app for this machine (dev)"
	@echo "  make test     - run LocalClipTestRunner"
	@echo "  make install  - alias of package (installs to ~/Applications)"
	@echo "  make open     - open installed app"
	@echo "  make clean    - remove .build and dist intermediates"

release:
	@chmod +x "$(ROOT)/Scripts/release.sh"
	@"$(ROOT)/Scripts/release.sh"

package install:
	@chmod +x "$(ROOT)/Scripts/package-app.sh"
	@"$(ROOT)/Scripts/package-app.sh"

test:
	@swift run -c release LocalClipTestRunner

open:
	@open "$(HOME)/Applications/LocalClip.app"

clean:
	@rm -rf "$(ROOT)/.build" "$(ROOT)/dist/universal-build"
	@echo "Cleaned .build and dist/universal-build (kept release artifacts in dist/)"
