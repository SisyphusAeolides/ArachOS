SHELL := /bin/bash

PROJECT_ROOT ?= $(abspath ..)
BUILD_DIR ?= $(CURDIR)/build
RUSTD_SOURCE_ROOT ?= $(PROJECT_ROOT)/rustd
RESOLVED_SOURCE_ROOT ?= $(PROJECT_ROOT)/rustd-resolved
TUNED_SOURCE_ROOT ?= $(PROJECT_ROOT)/tuned-rs
LIBINPUT_SOURCE_ROOT ?= $(PROJECT_ROOT)/libinput-rs
BLERUST_SOURCE_ROOT ?= $(PROJECT_ROOT)/blerust
CCZE_SOURCE_ROOT ?= $(PROJECT_ROOT)/ccze-rs

.PHONY: verify-sources build-rpms validate-rpms build-live validate clean

verify-sources:
	RUSTD_SOURCE_ROOT="$(RUSTD_SOURCE_ROOT)" \
	RESOLVED_SOURCE_ROOT="$(RESOLVED_SOURCE_ROOT)" \
	TUNED_SOURCE_ROOT="$(TUNED_SOURCE_ROOT)" \
	LIBINPUT_SOURCE_ROOT="$(LIBINPUT_SOURCE_ROOT)" \
	BLERUST_SOURCE_ROOT="$(BLERUST_SOURCE_ROOT)" \
	CCZE_SOURCE_ROOT="$(CCZE_SOURCE_ROOT)" \
	bash scripts/verify-sources.sh

build-rpms: verify-sources
	RUSTD_SOURCE_ROOT="$(RUSTD_SOURCE_ROOT)" \
	RESOLVED_SOURCE_ROOT="$(RESOLVED_SOURCE_ROOT)" \
	TUNED_SOURCE_ROOT="$(TUNED_SOURCE_ROOT)" \
	LIBINPUT_SOURCE_ROOT="$(LIBINPUT_SOURCE_ROOT)" \
	BLERUST_SOURCE_ROOT="$(BLERUST_SOURCE_ROOT)" \
	CCZE_SOURCE_ROOT="$(CCZE_SOURCE_ROOT)" \
	RPM_OUTPUT="$(BUILD_DIR)/repo" \
	bash scripts/build-rpms.sh

validate-rpms:
	RPM_REPO="$(BUILD_DIR)/repo" bash scripts/validate-rpms.sh

build-live: build-rpms
	RPM_REPO="$(BUILD_DIR)/repo" ISO_OUTPUT="$(BUILD_DIR)/iso" \
		RUSTD_SOURCE_ROOT="$(RUSTD_SOURCE_ROOT)" \
		bash scripts/build-live.sh

validate: verify-sources validate-rpms

clean:
	rm -rf "$(BUILD_DIR)"
