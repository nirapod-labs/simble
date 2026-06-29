# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs

SHELL := /bin/bash
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

SIM_SDK      := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
SIM_TARGET   := arm64-apple-ios17.0-simulator
WATCH_SDK    := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk watchsimulator --show-sdk-path 2>/dev/null)
WATCH_TARGET := arm64-apple-watchos10.0-simulator
SWIFT_PKGS   := packages/host-core packages/protocol/swift apps/helper tools/simblectl
C_FILES      := $(shell find packages -type f \( -name '*.c' -o -name '*.h' \) 2>/dev/null)

.PHONY: help bootstrap configure build app dylib test test-portable fence docs lint format clean \
        mechanism-ios mechanism-watchos mechanism-peripheral-ios

help: ## Show targets
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-24s %s\n", $$1, $$2}'

bootstrap: ## Fresh clone setup
	@command -v brew >/dev/null && brew bundle || echo "brew not found; skipping Brewfile"
	pnpm install
	pnpm exec lefthook install
	@$(MAKE) configure

configure: ## Configure host and simulator build trees
	cmake -S . -B build -DCMAKE_OSX_ARCHITECTURES=arm64
ifneq ($(SIM_SDK),)
	cmake -S . -B build-sim -DSIMBLE_SIM_SLICE=ON -DSIMBLE_SIM_PLATFORM=ios \
	  -DCMAKE_OSX_SYSROOT="$(SIM_SDK)" -DCMAKE_OSX_ARCHITECTURES=arm64 \
	  -DCMAKE_C_FLAGS="-target $(SIM_TARGET)" -DCMAKE_CXX_FLAGS="-target $(SIM_TARGET)"
endif
ifneq ($(WATCH_SDK),)
	cmake -S . -B build-watchsim -DSIMBLE_SIM_SLICE=ON -DSIMBLE_SIM_PLATFORM=watchos \
	  -DCMAKE_OSX_SYSROOT="$(WATCH_SDK)" -DCMAKE_OSX_ARCHITECTURES=arm64 \
	  -DCMAKE_C_FLAGS="-target $(WATCH_TARGET)" -DCMAKE_CXX_FLAGS="-target $(WATCH_TARGET)"
endif

build: configure ## Build C targets and Swift packages
	cmake --build build -j
	@if [ -d build-sim ]; then cmake --build build-sim -j; fi
	@if [ -d build-watchsim ]; then cmake --build build-watchsim -j; fi
	@for p in $(SWIFT_PKGS); do echo "== swift build: $$p =="; ( cd $$p && xcrun swift build ) || exit 1; done

dylib: configure ## Build the interposer simulator slices (ios and watchos)
	@if [ -d build-sim ]; then cmake --build build-sim -j; fi
	@if [ -d build-watchsim ]; then cmake --build build-watchsim -j; fi

app: ## Build the menubar SimBLE.app bundle into dist/ (ad-hoc signed)
	bash scripts/build-menubar-app.sh

test: build ## Run C tests, Swift tests, and the fence
	ctest --test-dir build --output-on-failure
	@for p in $(SWIFT_PKGS); do echo "== swift test: $$p =="; ( cd $$p && xcrun swift test ) || exit 1; done
	@bash scripts/fence-check.sh

test-portable: configure ## Run checks that do not need BLE hardware
	cmake --build build -j
	ctest --test-dir build --output-on-failure
	bash scripts/fence-check.sh

fence: ## Run static fence checks
	bash scripts/fence-check.sh

docs: ## Generate C API docs and fail on warnings
	doxygen Doxyfile

mechanism-ios: ## Run the iOS central in-simulator lane (operator, needs Bluetooth and a BLE peer)
	bash packages/interpose/tests/run-mechanism-central.sh ios

mechanism-watchos: ## Run the watchOS central in-simulator lane (operator, needs Bluetooth and a BLE peer)
	bash packages/interpose/tests/run-mechanism-central.sh watchos

mechanism-peripheral-ios: ## Run the iOS peripheral in-simulator lane (operator, needs Bluetooth)
	bash packages/interpose/tests/run-mechanism-peripheral-ios.sh

lint: ## biome, swiftlint, and clang-tidy
	pnpm exec biome check .
	-swiftlint lint --quiet
	-clang-tidy -p build $(filter %.c,$(C_FILES))

format: ## biome, swiftformat, and clang-format
	pnpm exec biome format --write .
	-swiftformat . --quiet
	-clang-format -i $(C_FILES)

clean: ## Remove build outputs
	rm -rf build build-sim build-watchsim .turbo
