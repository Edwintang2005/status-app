SIM ?= iPhone 17
SCHEME := RedString
PROJECT := RedString.xcodeproj
BUNDLE_ID := com.edwintang.redstring

.PHONY: project build test run archive clean

## Regenerate RedString.xcodeproj from project.yml (run after adding files)
project:
	xcodegen generate

## Compile check only — no signing, so the result must NOT be launched.
## Without the App Group entitlement the app fatal-errors on startup
## (GroupState.swift): the widget channel is a file in the group container,
## and there is no offline fallback. Use `make run` to actually run it.
build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug CODE_SIGNING_ALLOWED=NO build

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
