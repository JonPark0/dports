PACKAGE  := dports
VERSION  := $(shell grep '^DPORTS_VERSION=' dports.bash | cut -d'"' -f2)
ARCH     ?= all
DEB_NAME := $(PACKAGE)_$(VERSION)_$(ARCH).deb
BUILD_DIR := build/$(PACKAGE)_$(VERSION)_$(ARCH)

.PHONY: all deb check test clean

all: deb

## Build the .deb package
deb: $(DEB_NAME)

$(DEB_NAME): dports.bash dports.fish completions/dports.fish debian/control debian/changelog debian/copyright debian/postinst debian/prerm
	@echo "Building $(DEB_NAME) ..."

	# Start from a clean tree so files removed from the package do not linger
	rm -rf $(BUILD_DIR)

	# Create directory structure
	mkdir -p $(BUILD_DIR)/DEBIAN
	mkdir -p $(BUILD_DIR)/usr/bin
	mkdir -p $(BUILD_DIR)/usr/share/fish/vendor_functions.d
	mkdir -p $(BUILD_DIR)/usr/share/fish/vendor_completions.d
	mkdir -p $(BUILD_DIR)/usr/share/doc/$(PACKAGE)

	# Install files
	install -m 755 dports.bash      $(BUILD_DIR)/usr/bin/$(PACKAGE)
	install -m 644 dports.fish      $(BUILD_DIR)/usr/share/fish/vendor_functions.d/$(PACKAGE).fish
	install -m 644 completions/dports.fish $(BUILD_DIR)/usr/share/fish/vendor_completions.d/$(PACKAGE).fish
	install -m 644 debian/copyright $(BUILD_DIR)/usr/share/doc/$(PACKAGE)/copyright
	gzip -9 -n -c debian/changelog > $(BUILD_DIR)/usr/share/doc/$(PACKAGE)/changelog.Debian.gz

	# Update version in the installed binary
	sed -i 's/^DPORTS_VERSION=.*/DPORTS_VERSION="$(VERSION)"/' $(BUILD_DIR)/usr/bin/$(PACKAGE)

	# Install DEBIAN metadata
	sed -e 's/^Version:.*/Version: $(VERSION)/' \
	    -e 's/^Architecture:.*/Architecture: $(ARCH)/' \
	    debian/control > $(BUILD_DIR)/DEBIAN/control
	install -m 755 debian/postinst  $(BUILD_DIR)/DEBIAN/postinst
	install -m 755 debian/prerm     $(BUILD_DIR)/DEBIAN/prerm

	# Build the package
	dpkg-deb --build --root-owner-group $(BUILD_DIR) $(DEB_NAME)
	@echo "Done: $(DEB_NAME)"

## Syntax-check all scripts (shellcheck and fish are used when installed)
check:
	bash -n dports.bash
	bash -n install.sh
	sh -n debian/postinst
	sh -n debian/prerm
	@if command -v fish >/dev/null 2>&1; then \
		echo "fish -n dports.fish completions/dports.fish"; \
		fish -n dports.fish && fish -n completions/dports.fish; \
	else echo "fish not installed; skipping fish syntax check"; fi
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck -S warning dports.bash install.sh debian/postinst debian/prerm"; \
		shellcheck -S warning dports.bash install.sh debian/postinst debian/prerm; \
	else echo "shellcheck not installed; skipping lint"; fi
	@echo "Version: $(VERSION)"
	@grep -q 'set -g DPORTS_VERSION "$(VERSION)"' dports.fish || { echo "dports.fish version differs from $(VERSION)"; exit 1; }
	@grep -q '^VERSION="$(VERSION)"' install.sh || { echo "install.sh version differs from $(VERSION)"; exit 1; }

## Run the tests (a fake docker CLI stands in for Docker)
test:
	tests/test_update.sh

## Remove build artifacts
clean:
	rm -rf build/ dist/ *.deb
