PREFIX ?= /usr/local
APP = rec.app

# Prefer a stable signing identity when one exists: ad-hoc signatures change
# on every build, which makes macOS silently drop the app's TCC grants
# (Microphone, Screen Recording). Override with SIGN=- to force ad-hoc.
SIGN ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')
ifeq ($(SIGN),)
SIGN = -
endif

rec: Sources/main.swift Info.plist
	swiftc -O Sources/main.swift -o rec \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
	codesign --force --sign "$(SIGN)" rec

app: rec build/AppIcon.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp rec $(APP)/Contents/MacOS/rec
	cp build/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign "$(SIGN)" $(APP)

build/AppIcon.icns: scripts/makeicon.swift
	mkdir -p build
	swift scripts/makeicon.swift build
	iconutil -c icns -o build/AppIcon.icns build/AppIcon.iconset

install: rec
	install -m 755 rec $(PREFIX)/bin/rec

install-app: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/

clean:
	rm -rf rec $(APP) build

.PHONY: app install install-app clean
