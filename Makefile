# LocalClip — macOS menu bar clipboard (local-only)
#
# make release  → universal .app (arm64 + x86_64) + ZIP + DMG
# make package  → host-arch .app only (faster, for dev)
# make public   → local universal package + tag + push (CI publishes assets)
# make test     → unit runner
# make clean    → remove build/dist intermediates
#
# Optional: make public VERSION=1.0.1

.PHONY: release package test clean install open help public

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SHELL := /bin/bash

help:
	@echo "LocalClip targets:"
	@echo "  make release         - universal Intel+Apple silicon package (ZIP + DMG)"
	@echo "  make package         - single-arch .app for this machine (dev)"
	@echo "  make public          - auto patch bump + local package + tag + push"
	@echo "  make public VERSION=1.2.0  - explicit version + tag + push"
	@echo "  make test            - run LocalClipTestRunner"
	@echo "  make install         - alias of package (updates the existing app location)"
	@echo "  make open            - open installed app"
	@echo "  make clean           - remove .build and dist intermediates"

release:
	@chmod +x "$(ROOT)/Scripts/release.sh"
	@"$(ROOT)/Scripts/release.sh"

package install:
	@chmod +x "$(ROOT)/Scripts/package-app.sh"
	@"$(ROOT)/Scripts/package-app.sh"

public:
	@chmod +x "$(ROOT)/Scripts/public-release.sh"
	@export VERSION="$(VERSION)"; "$(ROOT)/Scripts/public-release.sh"

test:
	@source "$(ROOT)/Scripts/swift-env.sh"; localclip_configure_swift_env "$(ROOT)"; swift run -c release LocalClipTestRunner
	@bash "$(ROOT)/Scripts/tests/test-public-release.sh"

open:
	@source "$(ROOT)/Scripts/install-path.sh"; open "$$(localclip_install_app)"

clean:
	@rm -rf "$(ROOT)/.build" "$(ROOT)/dist/universal-build"
	@echo "Cleaned .build and dist/universal-build (kept release artifacts in dist/)"
