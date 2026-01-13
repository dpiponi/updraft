# Makefile for Updraft
# Usage:
#   make app                 # build + (auto) icon + bundle
#   make run ARGS="~/Desktop/Principles.pdf"
#   make clean               # remove .app + derived icon artifacts
#
# Notes:
# - This Makefile does NOT run `swift package clean` on each build (fast incremental builds).
# - It auto-regenerates AppIcon.icns when AppIcon.png changes.
# - It warns if Info.plist icon keys are missing/mismatched.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

APP_NAME      := Updraft
PRODUCT_NAME  := updraft
CONFIG        := release

ROOT_DIR      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR     := $(ROOT_DIR)/.build/$(CONFIG)
BIN_SRC       := $(BUILD_DIR)/$(PRODUCT_NAME)

APP_DIR       := $(ROOT_DIR)/$(APP_NAME).app
CONTENTS_DIR  := $(APP_DIR)/Contents
MACOS_DIR     := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources

INFO_PLIST_SRC := $(ROOT_DIR)/AppResources/Info.plist
INFO_PLIST_DST := $(CONTENTS_DIR)/Info.plist

ICON_PNG    := $(ROOT_DIR)/AppResources/AppIcon.png
ICONSET_DIR := $(ROOT_DIR)/AppResources/AppIcon.iconset
ICON_ICNS   := $(ROOT_DIR)/AppResources/AppIcon.icns
ICON_DST    := $(RESOURCES_DIR)/AppIcon.icns

PLISTBUDDY := /usr/libexec/PlistBuddy
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all app build bundle icon clean run lsregister check-plist

all: app

# Build SwiftPM product (incremental; no "swift package clean" here)
build:
	@echo "Building…"
	swift build -c "$(CONFIG)"
	@test -f "$(BIN_SRC)" || (echo "ERROR: Expected executable not found at: $(BIN_SRC)" >&2; exit 1)
	@test -f "$(INFO_PLIST_SRC)" || (echo "ERROR: Missing Info.plist at: $(INFO_PLIST_SRC)" >&2; exit 1)

# Generate AppIcon.icns from AppIcon.png (auto-runs when PNG changes)
icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_PNG)
	@echo "Generating iconset…"
	mkdir -p "$(ICONSET_DIR)"
	sips -z 16 16     "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_16x16.png" >/dev/null
	sips -z 32 32     "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_16x16@2x.png" >/dev/null
	sips -z 32 32     "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_32x32.png" >/dev/null
	sips -z 64 64     "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_32x32@2x.png" >/dev/null
	sips -z 128 128   "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_128x128.png" >/dev/null
	sips -z 256 256   "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_128x128@2x.png" >/dev/null
	sips -z 256 256   "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_256x256.png" >/dev/null
	sips -z 512 512   "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_256x256@2x.png" >/dev/null
	sips -z 512 512   "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_512x512.png" >/dev/null
	sips -z 1024 1024 "$(ICON_PNG)" --out "$(ICONSET_DIR)/icon_512x512@2x.png" >/dev/null
	@echo "Converting iconset -> icns…"
	iconutil -c icns "$(ICONSET_DIR)" -o "$(ICON_ICNS)"

# Warn if Info.plist icon keys are missing/mismatched.
# (Non-fatal: your app may still show an icon due to CFBundleIconFile alone.)

check-plist:
	@echo "Checking Info.plist icon configuration…"
	@plist="$(INFO_PLIST_SRC)"; pb="$(PLISTBUDDY)"; \
	iconfile="$$( "$$pb" -c 'Print :CFBundleIconFile' "$$plist" 2>/dev/null || true )"; \
	iconname="$$( "$$pb" -c 'Print :CFBundleIconName' "$$plist" 2>/dev/null || true )"; \
	if "$$pb" -c 'Print :CFBundleIcons' "$$plist" >/dev/null 2>&1; then hasicons=1; else hasicons=0; fi; \
	if [[ -z "$$iconfile" && -z "$$iconname" && "$$hasicons" -eq 0 ]]; then \
		echo "WARNING: Info.plist has no CFBundleIconFile, CFBundleIconName, or CFBundleIcons." >&2; \
		echo "         macOS may not pick up AppIcon.icns reliably." >&2; \
	elif [[ -n "$$iconfile" ]]; then \
		base="$${iconfile%.icns}"; \
		if [[ "$$base" != "AppIcon" ]]; then \
			echo "WARNING: CFBundleIconFile is '$$iconfile' (expected 'AppIcon' or 'AppIcon.icns')." >&2; \
		fi; \
	fi

# Bundle the .app (depends on build + icon; always tries to include icon)
bundle: build icon check-plist
	@echo "Bundling app…"
	rm -rf "$(APP_DIR)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	cp "$(BIN_SRC)" "$(MACOS_DIR)/$(PRODUCT_NAME)"
	cp "$(INFO_PLIST_SRC)" "$(INFO_PLIST_DST)"
	chmod +x "$(MACOS_DIR)/$(PRODUCT_NAME)"
	cp "$(ICON_ICNS)" "$(ICON_DST)"
	@echo "Icon: $(ICON_DST)"
	@$(MAKE) --no-print-directory lsregister
	touch "$(APP_DIR)" || true
	@echo "Done: $(APP_DIR)"

app: bundle

lsregister:
	@if [[ -x "$(LSREGISTER)" ]]; then \
		"$(LSREGISTER)" -f "$(APP_DIR)" >/dev/null 2>&1 || true; \
	fi

run: app
	"$(APP_DIR)/Contents/MacOS/$(PRODUCT_NAME)" $(ARGS)

clean:
	rm -rf "$(APP_DIR)" "$(ICONSET_DIR)" "$(ICON_ICNS)"
