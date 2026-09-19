# Common tasks for Skein.
#
# Run `make` or `make help` for the list.

# Prefer whatever `swift` is on PATH, but fall back to Xcode's toolchain when it
# is broken. A swiftly-managed toolchain whose directory has been removed still
# leaves a `swift` on PATH that fails on every invocation, which otherwise makes
# every target here fail for a reason that has nothing to do with the project.
SWIFT          := $(shell swift --version >/dev/null 2>&1 \
                    && echo swift || echo "xcrun --toolchain default swift")

WORKSPACE      := Skein.xcworkspace
SCHEME         := Skein
ENGINE_SCHEME  := TorrentKit
DERIVED_MAC    := .build/mac-dd
DERIVED_IOS    := .build/ios-dd
APP            := $(DERIVED_MAC)/Build/Products/Debug/Skein.app

# Local.env holds the bundle id and team identifier and is gitignored. The
# leading dash keeps make quiet when it does not exist yet.
#
# The variables must be exported for Tuist to see them: it evaluates Project.swift
# in a sandbox that exposes only TUIST_-prefixed environment variables, and can
# neither read Local.env from disk nor see unprefixed ones.
# Read with `?=` rather than `-include`, so a value already in the environment
# wins over the file — `-include` performs a plain assignment, which would
# override it and leave CI unable to steer a developer's checkout.
ifneq ($(wildcard Local.env),)
TUIST_BUNDLE_ID ?= $(shell sed -n 's/^[[:space:]]*TUIST_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' Local.env)
TUIST_DEVELOPMENT_TEAM ?= $(shell sed -n 's/^[[:space:]]*TUIST_DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' Local.env)
endif
export TUIST_BUNDLE_ID
export TUIST_DEVELOPMENT_TEAM

# A team identifier is about running on an iOS device, so it should not make a
# quick local Mac build start demanding certificates. macOS therefore builds
# unsigned unless you ask for `app-macos-signed`; only iOS picks up the team.
ifeq ($(strip $(TUIST_DEVELOPMENT_TEAM)),)
IOS_SIGNING := CODE_SIGNING_ALLOWED=NO
else
IOS_SIGNING := DEVELOPMENT_TEAM=$(TUIST_DEVELOPMENT_TEAM)
endif

.DEFAULT_GOAL := help
.PHONY: help bootstrap openssl build test test-live generate assets \
        app-macos app-macos-signed app-ios run clean clean-all lint config

help: ## Show this help
	@echo "Skein — common tasks"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Local settings come from Local.env (gitignored)."
	@echo "Start with:  cp Local.env.example Local.env"

# MARK: - Dependencies

bootstrap: ## Fetch libtorrent and Boost headers
	./Scripts/bootstrap.sh

openssl: ## Build the OpenSSL xcframework (slow; five Configure+make runs)
	./Scripts/build-openssl.sh

# MARK: - Engine

build: ## Build the engine package
	$(SWIFT) build

test: ## Run the engine tests (no network)
	$(SWIFT) test

test-live: ## Also run the tests that talk to the public swarm
	TORRENTKIT_LIVE_TESTS=1 $(SWIFT) test

# MARK: - Apps

assets: ## Re-render the app icon and accent colour
	$(SWIFT) Scripts/make-assets.swift

generate: ## Regenerate the Xcode project from Project.swift
	tuist generate --no-open

$(WORKSPACE):
	$(MAKE) generate

app-macos: $(WORKSPACE) ## Build the macOS app (unsigned)
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(DERIVED_MAC) CODE_SIGNING_ALLOWED=NO build

app-macos-signed: $(WORKSPACE) ## Build the macOS app with your Developer ID
	@test -n "$(strip $(TUIST_DEVELOPMENT_TEAM))" \
		|| { echo "Set TUIST_DEVELOPMENT_TEAM in Local.env first."; exit 1; }
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(DERIVED_MAC) \
		DEVELOPMENT_TEAM=$(TUIST_DEVELOPMENT_TEAM) build

app-ios: $(WORKSPACE) ## Build the iOS app for a device
	@test -n "$(strip $(TUIST_DEVELOPMENT_TEAM))" \
		|| echo "note: no TUIST_DEVELOPMENT_TEAM set — building unsigned, which will not install on a device"
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED_IOS) $(IOS_SIGNING) build

run: app-macos ## Build and launch the macOS app
	@# Launched through LaunchServices on purpose: exec'ing the binary gives it
	@# no window-server session, so SwiftUI never renders and the engine never
	@# starts.
	@codesign --force --deep --sign - $(APP) >/dev/null 2>&1 || true
	open $(APP)

# MARK: - Housekeeping

lint: ## Run SwiftLint over our own sources
	@command -v swiftlint >/dev/null 2>&1 \
		|| { echo "swiftlint not installed: brew install swiftlint"; exit 1; }
	swiftlint lint --quiet Sources App

config: ## Show the resolved bundle id and team
	@echo "bundle id:        $(if $(TUIST_BUNDLE_ID),$(TUIST_BUNDLE_ID),dev.soumyamahunt.skein (default))"
	@echo "development team: $(if $(TUIST_DEVELOPMENT_TEAM),$(TUIST_DEVELOPMENT_TEAM),none — unsigned builds)"
	@echo "swift:            $(SWIFT)"
	@test -f Local.env || echo "(no Local.env — cp Local.env.example Local.env)"

clean: ## Remove build output, keeping fetched dependencies
	rm -rf .build/mac-dd .build/ios-dd .build/ios-app-dd
	$(SWIFT) package clean

clean-all: clean ## Also remove the generated project and vendored OpenSSL
	rm -rf Skein.xcworkspace Skein.xcodeproj Derived .build/openssl Vendor/openssl
