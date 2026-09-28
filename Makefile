SWIFT       = /usr/bin/swift
BIN_DIR    ?= /usr/local/bin
KERNEL_DST  = $(HOME)/.podium/vmlinux
KERNEL_SRC ?= $(shell ls -t "$(HOME)/Library/Application Support/com.apple.container/kernels"/vmlinux-* 2>/dev/null | head -1)
DIST_DIR    ?= dist
VERSION     ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
SIGN_IDENTITY ?=
NOTARY_PROFILE ?= podium-notary
RELEASE_BINARY = $(DIST_DIR)/podium
RELEASE_ARCHIVE = $(DIST_DIR)/podium-$(VERSION)-macos-arm64.zip

LABEL ?= io.github.pgstr.podium
PLIST = $(HOME)/Library/LaunchAgents/$(LABEL).plist
PLIST_TEMPLATE = podium.plist.tmpl
DIRECT_PLIST_TEMPLATE = podium.direct.plist.tmpl
STACK ?= examples/stack.json

.PHONY: all build test runtime-assets install-cli install install-direct restart uninstall-cli uninstall kernel selftest proto clean \
	release release-sign release-archive release-notarize release-verify notary-setup

all: build

# Compile + codesign → stages ./podium only. Does NOT touch the installed binary.
# Use ./podium to test before committing to an install.
build:
	$(SWIFT) build -c release
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		codesign --force --timestamp --options runtime --sign "$(SIGN_IDENTITY)" \
			--entitlements podium.entitlements ./.build/release/podium; \
	else \
		codesign --force --sign - --entitlements podium.entitlements ./.build/release/podium; \
	fi
	rm -f ./podium                      # fresh inode: avoid stale code-sign cache on re-sign
	cp ./.build/release/podium ./podium
	@echo "staged -> ./podium  (run 'make install-cli' to deploy)"

test:
	$(SWIFT) test

# Distribution build. SIGN_IDENTITY must name a Developer ID Application
# identity installed in the signing keychain. Credentials never enter this
# repository; NOTARY_PROFILE refers to a notarytool profile in the Keychain.
release-sign:
	@test -n "$(SIGN_IDENTITY)" || (echo "ERROR: set SIGN_IDENTITY to your Developer ID Application identity"; exit 2)
	@security find-identity -v -p codesigning | grep -F "$(SIGN_IDENTITY)" >/dev/null || \
		(echo "ERROR: signing identity not found: $(SIGN_IDENTITY)"; exit 2)
	$(SWIFT) build -c release
	mkdir -p $(DIST_DIR)
	rm -f $(RELEASE_BINARY) $(RELEASE_ARCHIVE)
	cp ./.build/release/podium $(RELEASE_BINARY)
	codesign --force --timestamp --options runtime --sign "$(SIGN_IDENTITY)" \
		--entitlements podium.entitlements $(RELEASE_BINARY)
	codesign --verify --strict --verbose=2 $(RELEASE_BINARY)

# Apple accepts ZIP archives for custom notarization workflows. The ticket is
# published for Gatekeeper; raw command-line tools do not have a staplable
# bundle container, so verification assesses the signed executable itself.
release-archive: release-sign
	ditto -c -k --sequesterRsrc $(RELEASE_BINARY) $(RELEASE_ARCHIVE)
	@echo "archive -> $(RELEASE_ARCHIVE)"

release-notarize: release-archive
	@test -n "$(NOTARY_PROFILE)" || (echo "ERROR: set NOTARY_PROFILE"; exit 2)
	xcrun notarytool submit $(RELEASE_ARCHIVE) --keychain-profile "$(NOTARY_PROFILE)" --wait

release-verify: release-notarize
	codesign --verify --strict --verbose=2 $(RELEASE_BINARY)
	spctl --assess --type execute --verbose=4 $(RELEASE_BINARY)

release: test release-verify
	@echo "release accepted -> $(RELEASE_ARCHIVE)"

# Interactive one-time setup; stores credentials in the login Keychain.
notary-setup:
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)"

# Materialize every runtime asset while the installer is expected to have
# network access. Daemon cold starts then need neither GHCR nor the container
# CLI; service-image pulls remain an operator concern.
runtime-assets: build kernel
	./podium prepare-runtime
	@echo "runtime assets ready (kernel + vminit 0.46.0)"

# Deploy the staged binary to PATH. Safe to run against a live daemon —
# the daemon holds its own file handle so replacing the inode is atomic.
install-cli: runtime-assets
	sudo install -m 755 ./podium $(BIN_DIR)/podium
	@echo "installed -> $(BIN_DIR)/podium"

uninstall-cli:
	rm -f $(BIN_DIR)/podium
	@echo "removed $(BIN_DIR)/podium"

# Install the new binary and restart the running daemon.
# If a launchd agent is active it will relaunch automatically after bootout/bootstrap.
# If no agent is active, brings the daemon down so you can re-apply manually.
restart: install-cli
	@if launchctl list $(LABEL) >/dev/null 2>&1; then \
		echo "reloading launchd agent..."; \
		launchctl bootout  $(GUI)/$(LABEL) 2>/dev/null || true; \
		launchctl bootstrap $(GUI) $(PLIST); \
		echo "restarted via launchd"; \
	else \
		echo "no launchd agent active — sending podium down..."; \
		podium down 2>/dev/null || true; \
		echo "done. re-apply your stack to start with the new binary."; \
	fi

# Install the launchd LaunchAgent so the stack survives reboot (GUI session; needs auto-login).
# Override the stack with: make install STACK=examples/stack.json
GUI = gui/$(shell id -u)

install: install-cli
	sed -e "s#__WORKDIR__#$(CURDIR)#g" -e "s#__STACK__#$(CURDIR)/$(STACK)#g" -e "s#__HOME__#$(HOME)#g" \
		-e "s#__LABEL__#$(LABEL)#g" $(PLIST_TEMPLATE) > $(PLIST)
	launchctl bootout $(GUI)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap $(GUI) $(PLIST)
	@echo "LaunchAgent installed -> $(PLIST) (stack: $(STACK))"

# A Developer ID-signed binary can run directly under launchd with no localhost
# SSH/Remote Login dependency. Use `install` until such a certificate exists.
install-direct: install-cli
	@test -n "$(SIGN_IDENTITY)" || (echo "ERROR: install-direct requires SIGN_IDENTITY"; exit 2)
	@codesign -dv --verbose=4 $(BIN_DIR)/podium 2>&1 | grep -F "Authority=Developer ID Application" >/dev/null || \
		(echo "ERROR: installed podium is not Developer ID Application signed"; exit 2)
	mkdir -p $(HOME)/.podium
	sed -e "s#__WORKDIR__#$(CURDIR)#g" -e "s#__STACK__#$(CURDIR)/$(STACK)#g" \
		-e "s#__HOME__#$(HOME)#g" -e "s#__BINARY__#$(BIN_DIR)/podium#g" \
		-e "s#__LABEL__#$(LABEL)#g" $(DIRECT_PLIST_TEMPLATE) > $(PLIST)
	launchctl bootout $(GUI)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap $(GUI) $(PLIST)
	@echo "Direct LaunchAgent installed -> $(PLIST) (no Remote Login required)"

uninstall:
	launchctl bootout $(GUI)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST)
	@echo "LaunchAgent removed"

# Fetch a Linux kernel from the installed `container` tool (not committed; see .gitignore).
# Also copies to ~/.podium/vmlinux so `podium` works from any directory.
kernel:
	@mkdir -p $(HOME)/.podium
	@if [ -n "$(KERNEL_SRC)" ] && [ -f "$(KERNEL_SRC)" ]; then \
		install -m 644 "$(KERNEL_SRC)" ./vmlinux; \
		install -m 644 "$(KERNEL_SRC)" $(KERNEL_DST); \
		echo "kernel -> ./vmlinux and $(KERNEL_DST)"; \
	elif [ -f "$(KERNEL_DST)" ]; then \
		install -m 644 $(KERNEL_DST) ./vmlinux; \
		echo "kernel already installed -> $(KERNEL_DST)"; \
	else \
		echo "ERROR: no Apple container kernel found; install/start Apple container or set KERNEL_SRC=/path/to/vmlinux"; \
		exit 2; \
	fi

# Run the reconciler assertions against the staged binary (not the installed one).
selftest: build
	./podium selftest examples/stack.json

# Regenerate Sources/PodiumRPC/Generated from proto/podium.proto.
# Output is checked in, so builds never need protoc; plugin versions are
# pinned by Package.resolved, so regeneration is reproducible.
# Requires protoc on PATH (`brew install protobuf`).
proto:
	$(SWIFT) package plugin --allow-writing-to-package-directory \
		generate-grpc-code-from-protos \
		--access-level public \
		--import-path proto \
		--output-path Sources/PodiumRPC/Generated \
		-- proto/podium.proto

clean:
	$(SWIFT) package clean
	rm -f ./podium
