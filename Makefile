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
TUIST_EXPORT_COMPLIANCE_CODE ?= $(shell sed -n 's/^[[:space:]]*TUIST_EXPORT_COMPLIANCE_CODE[[:space:]]*=[[:space:]]*//p' Local.env)
# The App Store Connect key, so `make upload` signs and uploads without an
# Apple ID signed in to Xcode. The release script reads the rest itself.
ASC_ISSUER_ID ?= $(shell sed -n 's/^[[:space:]]*ASC_ISSUER_ID[[:space:]]*=[[:space:]]*//p' Local.env)
ASC_KEY_ID ?= $(shell sed -n 's/^[[:space:]]*ASC_KEY_ID[[:space:]]*=[[:space:]]*//p' Local.env)
ASC_PRIVATE_KEY_PATH ?= $(shell sed -n 's/^[[:space:]]*ASC_PRIVATE_KEY_PATH[[:space:]]*=[[:space:]]*//p' Local.env)
endif
export TUIST_BUNDLE_ID
export TUIST_DEVELOPMENT_TEAM
export TUIST_EXPORT_COMPLIANCE_CODE

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
        app-macos app-macos-signed app-ios run clean clean-all lint config \
        setup-app setup-app-plan archive upload listing listing-plan \
        screenshots screenshots-upload screenshots-upload-plan encryption encryption-plan \
        mac-archive mac-release mac-notarize notarize notarize-plan status \
        altstore-register release release-plan

help: ## Show this help
	@echo "Skein — common tasks"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
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

# MARK: - Release (alternative distribution only)
#
# Skein is never on the App Store. iOS builds go to App Store Connect only to be
# notarized for EU alternative marketplaces, then reach users through AltStore
# PAL from a GitHub release. The order is upload → notarize → release; see
# "Releasing" in README.md. The Release workflow runs `make release` in CI.

RELEASE        := $(SWIFT) Scripts/appstoreconnect.swift

setup-app-plan: ## Show what `make setup-app` would do
	$(RELEASE) setup --dry-run

setup-app: ## Register the bundle IDs and wait for the App Store Connect app record (once)
	$(RELEASE) setup

ARCHIVE        := build/Skein.xcarchive
# Every upload needs a higher build number; a timestamp always increases.
BUILD_NUMBER   ?= $(shell date +%Y%m%d%H%M)
ASC_KEY_FILE    = $(patsubst ~/%,$(HOME)/%,$(ASC_PRIVATE_KEY_PATH))
ASC_AUTH        = $(if $(strip $(ASC_KEY_ID)),-authenticationKeyPath "$(ASC_KEY_FILE)" \
                    -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID))

archive: generate ## Archive a Release iOS build (BUILD_NUMBER=… to override)
	@test -n "$(strip $(TUIST_DEVELOPMENT_TEAM))" \
		|| { echo "Set TUIST_DEVELOPMENT_TEAM in Local.env first."; exit 1; }
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
		-allowProvisioningUpdates $(ASC_AUTH) \
		DEVELOPMENT_TEAM=$(TUIST_DEVELOPMENT_TEAM) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) archive
	@echo "Archived build $(BUILD_NUMBER) at $(ARCHIVE)"

upload: archive ## Archive and upload to App Store Connect, ready for notarization
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportOptionsPlist ExportOptions.plist \
		-exportPath build/export -allowProvisioningUpdates $(ASC_AUTH)

# The Mac app ships outside any store: Developer ID signed, notarized by Apple,
# and attached to the same GitHub release as the iOS build. VERSION and
# BUILD_NUMBER let it match that build; RELEASE_TAG names the release.
MAC_ARCHIVE    := build/Skein-macOS.xcarchive

# Signed directly with the Developer ID Application certificate in the keychain
# rather than automatically: Apple's cloud-managed Developer ID signing refuses
# App Store Connect API keys, even Admin ones (FB16835802). Nothing Skein uses on
# the Mac needs a provisioning profile.
mac-archive: generate ## Archive a universal Release macOS build (VERSION=… BUILD_NUMBER=… to override)
	@test -n "$(strip $(TUIST_DEVELOPMENT_TEAM))" \
		|| { echo "Set TUIST_DEVELOPMENT_TEAM in Local.env first."; exit 1; }
	@security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($(TUIST_DEVELOPMENT_TEAM))" \
		|| { echo "No Developer ID Application certificate for team $(TUIST_DEVELOPMENT_TEAM) in the keychain."; \
		     echo "Create one in Xcode › Settings › Accounts › Manage Certificates › + (Account Holder only)."; exit 1; }
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=macOS' -archivePath $(MAC_ARCHIVE) \
		DEVELOPMENT_TEAM=$(TUIST_DEVELOPMENT_TEAM) CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="Developer ID Application" PROVISIONING_PROFILE_SPECIFIER= \
		CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) $(if $(VERSION),MARKETING_VERSION=$(VERSION)) archive

mac-release: mac-archive ## Sign with Developer ID, notarize, staple and zip the Mac app (RELEASE_TAG=… to attach it)
	ASC_KEY_FILE="$(ASC_KEY_FILE)" ASC_KEY_ID="$(ASC_KEY_ID)" ASC_ISSUER_ID="$(ASC_ISSUER_ID)" \
		RELEASE_TAG="$(RELEASE_TAG)" ./Scripts/mac-release.sh

mac-notarize: ## Retry notarizing, stapling and zipping the last Mac export without rebuilding
	ASC_KEY_FILE="$(ASC_KEY_FILE)" ASC_KEY_ID="$(ASC_KEY_ID)" ASC_ISSUER_ID="$(ASC_ISSUER_ID)" \
		RELEASE_TAG="$(RELEASE_TAG)" ./Scripts/mac-release.sh --notarize-only

listing-plan: ## Show the listing `make listing` would fill in
	$(RELEASE) listing --dry-run

listing: ## Fill in app info, age rating, version text and review notes (needs Local.env)
	$(RELEASE) listing

screenshots: $(WORKSPACE) ## Capture App Store Connect screenshots on the iPhone and iPad simulators
	./Scripts/screenshots.sh

screenshots-upload-plan: ## Show which screenshots `make screenshots-upload` would send
	$(RELEASE) screenshots --dry-run

screenshots-upload: ## Replace the version's screenshots with AppStore/screenshots (needs Local.env)
	$(RELEASE) screenshots

encryption-plan: ## Show the export compliance answers `make encryption` would file
	$(RELEASE) encryption --dry-run

encryption: ## File the export compliance declaration (once) and show whether Apple approved it
	$(RELEASE) encryption

notarize-plan: ## Show what `make notarize` would do
	$(RELEASE) notarize --dry-run

notarize: ## Attach the latest upload to the version and submit it for notarization
	$(RELEASE) notarize

status: ## Show version, notarization and ADP state
	$(RELEASE) status

altstore-register: ## Get an AltStore PAL marketplace token for App Store Connect (once)
	$(RELEASE) altstore-register

release-plan: ## Show what `make release` would do
	$(RELEASE) release --dry-run

release: ## Publish the notarized build as a GitHub release and add it to AltStore/source.json
	$(RELEASE) release

# MARK: - Housekeeping

lint: ## Run SwiftLint over our own sources
	@command -v swiftlint >/dev/null 2>&1 \
		|| { echo "swiftlint not installed: brew install swiftlint"; exit 1; }
	swiftlint lint --quiet Sources App

config: ## Show the resolved bundle id and team
	@echo "bundle id:        $(if $(TUIST_BUNDLE_ID),$(TUIST_BUNDLE_ID),Project.swift's default)"
	@echo "development team: $(if $(TUIST_DEVELOPMENT_TEAM),$(TUIST_DEVELOPMENT_TEAM),none — unsigned builds)"
	@echo "swift:            $(SWIFT)"
	@test -f Local.env || echo "(no Local.env — cp Local.env.example Local.env)"

clean: ## Remove build output, keeping fetched dependencies
	rm -rf .build/mac-dd .build/ios-dd .build/ios-app-dd .build/screenshots-dd build
	$(SWIFT) package clean

clean-all: clean ## Also remove the generated project and vendored OpenSSL
	rm -rf Skein.xcworkspace Skein.xcodeproj Derived .build/openssl Vendor/openssl
