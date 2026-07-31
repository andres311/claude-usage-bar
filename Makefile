# ClaudeUsage - thin wrapper around build.sh
# Everything that actually compiles lives in build.sh; this is just the front door.

APP_NAME := ClaudeUsage
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
DEST := $(HOME)/Applications/$(APP_NAME).app
ZIP := $(BUILD_DIR)/$(APP_NAME).zip
SOURCES := $(wildcard Sources/*.swift)
RESOURCES := $(wildcard Resources/*.png)
TESTS := $(BUILD_DIR)/tests

.DEFAULT_GOAL := help
.PHONY: build test install run stop zip clean uninstall help

## build: compile build/ClaudeUsage.app
# The echo is not decoration: without a recipe make answers an up-to-date .app with
# "Nothing to be done for `build'", which reads like a broken Makefile.
build: $(APP)
	@echo "==> $(APP) is up to date"

# Rebuild whenever a source file, a bundled resource or the build script changes.
# build.sh rm -rf's the .app before recreating it, so the directory's own mtime is a
# valid stamp here; without that it would never advance (writes land in Contents/).
$(APP): $(SOURCES) $(RESOURCES) build.sh
	./build.sh

## test: build and run the logic tests (no app bundle, no XCTest)
test: $(TESTS)
	@$(TESTS)

# Everything except App.swift: its `@main` cannot coexist with the top-level code in
# Tests/main.swift, and what it holds is NSStatusItem/NSPopover wiring that means nothing
# without a running app anyway.
TEST_SOURCES := $(filter-out Sources/App.swift,$(SOURCES))

$(TESTS): $(TEST_SOURCES) Tests/main.swift
	@mkdir -p $(BUILD_DIR)
	swiftc -o $(TESTS) $(TEST_SOURCES) Tests/main.swift \
		-framework AppKit -framework SwiftUI -framework ServiceManagement

## install: build, copy to ~/Applications and launch
install:
	./build.sh install

## run: build, then launch the app from build/ (restarts it if already running)
run: build stop
	open $(APP)

## stop: quit a running ClaudeUsage
stop:
	@pkill -x $(APP_NAME) 2>/dev/null || true

## zip: build a shareable build/ClaudeUsage.zip (ditto keeps the bundle intact)
zip: build
	@rm -f $(ZIP)
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(ZIP)
	@echo "==> $(ZIP) ($$(du -h $(ZIP) | cut -f1))"
	@echo "    ad-hoc signed: the receiver must run"
	@echo "    xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app"

## clean: remove build artifacts
clean:
	rm -rf $(BUILD_DIR)

## uninstall: quit and remove the copy in ~/Applications
uninstall: stop
	rm -rf $(DEST)
	@echo "==> Removed $(DEST)"

## help: list targets (the default goal, so a bare `make` builds nothing by surprise)
# Cyan on the command, nothing on the description. The `[ -t 1 ]` test is what keeps
# `make help | grep zip` (or a CI log) free of raw escape codes: no terminal, no color.
# awk does the padding so the descriptions line up whether or not the codes are there,
# since they are printed outside the %-14s field and do not count toward its width.
help:
	@if [ -t 1 ]; then color=1; else color=; fi; \
	echo "$(APP_NAME) - targets:"; \
	grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //' | \
	awk -F':' -v c="$${color:+\033[36m}" -v r="$${color:+\033[0m}" \
	    '{ d = substr($$0, index($$0, ":") + 2); \
	       printf "  %s%-14s%s %s\n", c, "make " $$1, r, d }'
