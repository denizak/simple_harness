# simple_harness — build & install
#
# Why a Makefile? SwiftPM has no "swift install" command: an executable is
# just a file under .build/<config>/. Installing a CLI therefore means:
#   1. build in release mode (-O optimizations)
#   2. copy the binary into a directory on your PATH
# These targets wrap exactly that. Debug builds (`make`) stay the fast path
# for iterating; only `install` pays the release-compile cost.
#
# Targets:
#   make            build (debug)   — fast iteration
#   make release    build (release) — optimized binary
#   make test       run the tool-layer selftest (no API calls)
#   make install    build release, copy to $(PREFIX)   (default ~/.local/bin)
#   make uninstall  remove the installed binary
#   make clean      delete .build
#
# Override the destination, e.g. with sudo:
#   sudo make install PREFIX=/usr/local/bin

BIN_NAME  := harness
PREFIX    ?= $(HOME)/.local/bin
BUILD_DIR := .build

.PHONY: all build release test install uninstall clean

all: build

build:
	swift build

release:
	swift build -c release

test: build
	$(BUILD_DIR)/debug/$(BIN_NAME) --selftest

install: release
	@mkdir -p $(PREFIX)
	install $(BUILD_DIR)/release/$(BIN_NAME) $(PREFIX)/$(BIN_NAME)
	@echo "installed: $(PREFIX)/$(BIN_NAME)"
	@echo "$$PATH" | tr ':' '\n' | grep -Fxq "$(PREFIX)" && echo "on PATH: yes" || echo "NOTE: $(PREFIX) is not on your PATH — add it to your shell profile."

uninstall:
	rm -f $(PREFIX)/$(BIN_NAME)
	@echo "removed: $(PREFIX)/$(BIN_NAME) (if present)"

clean:
	rm -rf $(BUILD_DIR)