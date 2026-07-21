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

app: rec
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	cp rec $(APP)/Contents/MacOS/rec
	codesign --force --sign "$(SIGN)" $(APP)

install: rec
	install -m 755 rec $(PREFIX)/bin/rec

install-app: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/

clean:
	rm -rf rec $(APP)

.PHONY: app install install-app clean
