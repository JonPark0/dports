PACKAGE  := dports
VERSION  := $(shell grep '^DPORTS_VERSION=' dports.bash | cut -d'"' -f2)
ARCH     ?= all
DEB_NAME := $(PACKAGE)_$(VERSION)_$(ARCH).deb
BUILD_DIR := build/$(PACKAGE)_$(VERSION)_$(ARCH)

.PHONY: all deb check test screenshots clean

all: deb

## Build the .deb package
deb: $(DEB_NAME)

$(DEB_NAME): dports.bash completions/dports.fish completions/_dports debian/control debian/changelog debian/copyright
	@echo "Building $(DEB_NAME) ..."

	# Start from a clean tree so files removed from the package do not linger
	rm -rf $(BUILD_DIR)

	# Create directory structure
	mkdir -p $(BUILD_DIR)/DEBIAN
	mkdir -p $(BUILD_DIR)/usr/bin
	mkdir -p $(BUILD_DIR)/usr/share/fish/vendor_completions.d
	mkdir -p $(BUILD_DIR)/usr/share/zsh/vendor-completions
	mkdir -p $(BUILD_DIR)/usr/share/doc/$(PACKAGE)

	# Install files
	# (Fish and Zsh run /usr/bin/dports directly; only their completions ship)
	install -m 755 dports.bash      $(BUILD_DIR)/usr/bin/$(PACKAGE)
	install -m 644 completions/dports.fish $(BUILD_DIR)/usr/share/fish/vendor_completions.d/$(PACKAGE).fish
	install -m 644 completions/_dports $(BUILD_DIR)/usr/share/zsh/vendor-completions/_$(PACKAGE)
	install -m 644 debian/copyright $(BUILD_DIR)/usr/share/doc/$(PACKAGE)/copyright
	gzip -9 -n -c debian/changelog > $(BUILD_DIR)/usr/share/doc/$(PACKAGE)/changelog.Debian.gz

	# Update version in the installed binary
	sed -i 's/^DPORTS_VERSION=.*/DPORTS_VERSION="$(VERSION)"/' $(BUILD_DIR)/usr/bin/$(PACKAGE)

	# Install DEBIAN metadata
	sed -e 's/^Version:.*/Version: $(VERSION)/' \
	    -e 's/^Architecture:.*/Architecture: $(ARCH)/' \
	    debian/control > $(BUILD_DIR)/DEBIAN/control

	# Do not depend on the caller's umask (CI containers may run with 000):
	# directories 755, files 644, executables 755
	chmod -R u=rwX,go=rX $(BUILD_DIR)

	# Build the package
	dpkg-deb --build --root-owner-group $(BUILD_DIR) $(DEB_NAME)
	@echo "Done: $(DEB_NAME)"

## Syntax-check all scripts (shellcheck, fish and zsh are used when installed)
check:
	bash -n dports.bash
	bash -n install.sh
	bash -n tests/test_update.sh
	@if command -v fish >/dev/null 2>&1; then \
		echo "fish -n dports.fish completions/dports.fish"; \
		fish -n dports.fish && fish -n completions/dports.fish; \
	else echo "fish not installed; skipping fish syntax check"; fi
	@if command -v zsh >/dev/null 2>&1; then \
		echo "zsh -n dports.zsh completions/_dports"; \
		zsh -n dports.zsh && zsh -n completions/_dports; \
	else echo "zsh not installed; skipping zsh syntax check"; fi
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck -S warning dports.bash install.sh"; \
		shellcheck -S warning dports.bash install.sh; \
	else echo "shellcheck not installed; skipping lint"; fi
	@echo "Version: $(VERSION)"
	@grep -q 'set -g DPORTS_VERSION "$(VERSION)"' dports.fish || { echo "dports.fish version differs from $(VERSION)"; exit 1; }
	@grep -q 'typeset -g DPORTS_VERSION="$(VERSION)"' dports.zsh || { echo "dports.zsh version differs from $(VERSION)"; exit 1; }
	@grep -q '^VERSION="$(VERSION)"' install.sh || { echo "install.sh version differs from $(VERSION)"; exit 1; }

## Run the tests (a fake docker CLI stands in for Docker)
test:
	tests/test_update.sh
	@if command -v python3 >/dev/null 2>&1; then \
		python3 tests/test_tui.py; \
	else echo "python3 not installed; skipping the full-screen tests"; fi

## Re-render the README images in docs/images (needs pyte and playwright)
screenshots:
	python3 docs/tools/screenshots.py

## Remove build artifacts
clean:
	rm -rf build/ dist/ *.deb
