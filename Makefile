SIM ?= iPhone 17 Pro
SCHEME := Tether
PROJECT := Tether.xcodeproj

.PHONY: project build test run clean

## Regenerate Tether.xcodeproj from project.yml (run after adding files)
project:
	xcodegen generate

## Build for the simulator without code signing
build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug CODE_SIGNING_ALLOWED=NO build

## Build, install and launch on the simulator
run: build
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
	@open -a Simulator
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/Tether.app; \
	xcrun simctl install "$(SIM)" "$$APP"; \
	xcrun simctl launch "$(SIM)" com.edwintang.tether

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf build DerivedData

## Fully working build with no CloudKit and no Apple Developer account: a
## fictional partner you drive from Settings → Demo controls.
##
## Xcode drops entitlements when it can't produce a provisioning profile, so
## the App Group is re-applied by hand afterwards. The Simulator honours it
## without a profile, which is what lets the widget share data with the app.
## Simulator only — a real device would reject the ad-hoc signature.
LOCAL_FLAGS := TETHER_CONDITIONS=TETHER_LOCAL_MODE CODE_SIGNING_ALLOWED=NO

local: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug $(LOCAL_FLAGS) build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug $(LOCAL_FLAGS) -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/Tether.app; \
	codesign -f -s - --entitlements Config/Local.entitlements \
		"$$APP/PlugIns/TetherWidgetExtension.appex"; \
	codesign -f -s - --entitlements Config/Local.entitlements "$$APP"; \
	xcrun simctl boot "$(SIM)" 2>/dev/null || true; \
	open -a Simulator; \
	xcrun simctl install "$(SIM)" "$$APP"; \
	xcrun simctl launch "$(SIM)" com.edwintang.tether
