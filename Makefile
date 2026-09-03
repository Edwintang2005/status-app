SIM ?= iPhone 17
SCHEME := RedString
PROJECT := RedString.xcodeproj
BUNDLE_ID := com.edwintang.redstring

.PHONY: project build test run device archive clean

## Regenerate RedString.xcodeproj from project.yml (run after adding files)
project:
	xcodegen generate

## Compile check only — no signing, so the result must NOT be launched.
## Without the App Group entitlement the app asserts on startup in Debug
## (GroupState.swift): the widget channel is a file in the group container,
## and there is no offline fallback. Use `make run` to actually run it.
build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug CODE_SIGNING_ALLOWED=NO build

## Unit tests. The test bundle compiles Sources/Shared directly (no host app),
## so this needs neither signing nor the App Group.
test: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug CODE_SIGNING_ALLOWED=NO \
		-only-testing:RedStringTests test

## Build signed, install and launch on the simulator. Needs DEVELOPMENT_TEAM
## set (project.yml or Xcode's Signing tab) — the App Group and CloudKit
## entitlements have to be in the binary for the app to get past launch, and
## a free personal team can't issue App Groups at all.
run: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug build
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
	@open -a Simulator
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/RedString.app; \
	xcrun simctl install "$(SIM)" "$$APP"; \
	xcrun simctl launch "$(SIM)" $(BUNDLE_ID)

## Build signed and install the Debug config on a connected iPhone.
##
## This is the ONLY way to reach the CloudKit *Development* environment: the
## environment is chosen by how the build is signed, so a TestFlight or
## archived build always talks to Production, where nothing is auto-created.
## Run this, tap "Create a link" once, and CloudKit adds `cloudkit.share` to
## the Development schema — which is what "Deploy Schema Changes" then has to
## promote. See "Shipping it" in README.md.
##
## Requires Developer Mode on the iPhone: Settings -> Privacy & Security ->
## Developer Mode -> on, then reboot. Without it the install is refused.
##
## DEVICE defaults to the first paired device; override with
##   make device DEVICE=<identifier from `xcrun devicectl list devices`>
## Grepped as a UUID rather than by column: the Model column contains spaces
## ("iPhone 14 Pro (iPhone15,2)"), so positional awk picks up the wrong field.
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | grep -w available | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)

device: project
	@test -n "$(DEVICE)" || { echo "No paired device found. Plug in an iPhone and trust this Mac."; exit 1; }
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' \
		-configuration Debug build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/RedString.app; \
	xcrun devicectl device install app --device $(DEVICE) "$$APP"

## Archive for TestFlight / App Store. Needs DEVELOPMENT_TEAM set (project.yml
## or Xcode's Signing tab) and the Release entitlements, which carry
## aps-environment=production.
archive: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' \
		-configuration Release \
		-archivePath build/RedString.xcarchive archive

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf build DerivedData
