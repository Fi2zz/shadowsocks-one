PROJECT := ShadowsocksOne.xcodeproj
SCHEME := Shadowsocks One
BUNDLE_ID := com.fits.socks.one
DEVICE_ID ?= 14EDD430-3B6F-5969-B920-F1C427404CA4
SIMULATOR ?= platform=iOS Simulator,name=iPhone 17
DERIVED_DATA := .build/derived-data
APP_PATH := $(DERIVED_DATA)/Build/Products/Debug-iphoneos/ShadowsocksOne.app

.PHONY: generate build test build-device install run

generate:
	xcodegen

build: generate
	xcodebuild -project $(PROJECT) -scheme "$(SCHEME)" \
		-destination 'generic/platform=iOS' \
		build CODE_SIGNING_ALLOWED=NO

test: generate
	xcodebuild -project $(PROJECT) -scheme "$(SCHEME)" \
		-destination '$(SIMULATOR)' \
		test

build-device: generate
	xcodebuild -project $(PROJECT) -scheme "$(SCHEME)" \
		-destination 'platform=iOS,id=$(DEVICE_ID)' \
		-derivedDataPath $(DERIVED_DATA) \
		-allowProvisioningUpdates \
		build

install: build-device
	xcrun devicectl device install app --device $(DEVICE_ID) "$(APP_PATH)"

run: install
	xcrun devicectl device process launch --device $(DEVICE_ID) $(BUNDLE_ID)
