.PHONY: gen build release run test diagnose
gen:
	xcodegen generate
build: gen
	xcodebuild -project Fader.xcodeproj -scheme Fader -configuration Debug -derivedDataPath build build
release: gen
	xcodebuild -project Fader.xcodeproj -scheme Fader -configuration Release -derivedDataPath build build
run: build
	open build/Build/Products/Debug/Fader.app
test:
	mkdir -p build
	xcrun clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g -I Fader/Audio Fader/Audio/RenderKernel.c Tests/RenderKernelTests.c -framework CoreAudio -o build/render-tests
	./build/render-tests
	xcrun swiftc -swift-version 6 -module-cache-path build/test-module-cache -import-objc-header Fader/Audio/Fader-Bridging-Header.h Fader/SourceSettings.swift Tests/SourceSettingsTests.swift -o build/settings-tests
	./build/settings-tests
diagnose: build
	build/Build/Products/Debug/Fader.app/Contents/MacOS/Fader --diagnose
