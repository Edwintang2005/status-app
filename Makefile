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
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$$2} / FULL_PRODUCT_NAME /{n=$$2} END{print d"/"n}'); \
	xcrun simctl install "$(SIM)" "$$APP"; \
	xcrun simctl launch "$(SIM)" com.edwintang.tether

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf build DerivedData

## Build with CloudKit compiled out — lets the UI run unsigned, before an
## Apple Developer team and iCloud container exist. Pairing will not work.
preview:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-configuration Debug CODE_SIGNING_ALLOWED=NO \
		TETHER_CONDITIONS=TETHER_NO_CLOUDKIT build
