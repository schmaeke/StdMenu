APP        := build/StdMenu.app
APPDIR     ?= $(HOME)/Applications
BINDIR     ?= $(HOME)/.local/bin
LABEL      := dev.schmaeke.stdmenu
AGENT      := $(HOME)/Library/LaunchAgents/$(LABEL).plist
CONFIG     := $(HOME)/.config/stdmenu/config
SOURCES    := $(wildcard Sources/*.swift)
SWIFTFLAGS := -O -swift-version 6 -target $(shell uname -m)-apple-macos14

all: $(APP)

$(APP): Makefile $(SOURCES) $(shell find Resources Support -type f)
	rm -rf $@
	mkdir -p $@/Contents/MacOS
	swiftc $(SWIFTFLAGS) -o $@/Contents/MacOS/stdmenu $(SOURCES)
	cp Support/Info.plist $@/Contents/
	cp -R Resources $@/Contents/
	codesign --force --sign - $@

# Installs the app, links the command, creates a config unless there is one, and starts the agent.
install: $(APP)
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	mkdir -p "$(APPDIR)" "$(BINDIR)" "$(dir $(AGENT))" "$(dir $(CONFIG))"
	rm -rf "$(APPDIR)/StdMenu.app"
	cp -R $(APP) "$(APPDIR)/"
	ln -sf "$(APPDIR)/StdMenu.app/Contents/MacOS/stdmenu" "$(BINDIR)/stdmenu"
	[ -e "$(CONFIG)" ] || cp Resources/config "$(CONFIG)"
	sed -e 's|@APP@|$(APPDIR)/StdMenu.app|' -e 's|@LOG@|$(HOME)/Library/Logs/stdmenu.log|' \
	    Support/$(LABEL).plist > "$(AGENT)"
	launchctl bootstrap gui/$$(id -u) "$(AGENT)"

# Leaves the config and the log in place.
uninstall:
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -rf "$(APPDIR)/StdMenu.app" "$(BINDIR)/stdmenu" "$(AGENT)"

# Regenerates the emoji list from Unicode's latest data, keeping the old one if that fails.
emoji:
	mkdir -p build
	scripts/emoji-tsv > build/emoji.tsv
	mv build/emoji.tsv Resources/emoji.tsv

icon:
	rm -rf build/StdMenu.iconset
	mkdir -p build/StdMenu.iconset
	swift scripts/icon.swift build/StdMenu.iconset
	iconutil --convert icns --output Resources/StdMenu.icns build/StdMenu.iconset

clean:
	rm -rf build

.PHONY: all install uninstall emoji icon clean
