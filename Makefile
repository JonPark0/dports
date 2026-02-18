PACKAGE  := dports
VERSION  := $(shell grep '^DPORTS_VERSION=' dports.bash | cut -d'"' -f2)
ARCH     := all
DEB_NAME := $(PACKAGE)_$(VERSION)_$(ARCH).deb
BUILD_DIR := build/$(PACKAGE)_$(VERSION)_$(ARCH)

.PHONY: all deb clean

all: deb

## Build the .deb package
deb: $(DEB_NAME)

$(DEB_NAME): dports.bash dports.fish debian/control debian/changelog debian/copyright debian/postinst debian/prerm
	@echo "Building $(DEB_NAME) ..."

	# Create directory structure
	mkdir -p $(BUILD_DIR)/DEBIAN
	mkdir -p $(BUILD_DIR)/usr/bin
	mkdir -p $(BUILD_DIR)/usr/share/fish/vendor_functions.d
	mkdir -p $(BUILD_DIR)/usr/share/doc/$(PACKAGE)

	# Install files
	install -m 755 dports.bash      $(BUILD_DIR)/usr/bin/$(PACKAGE)
	install -m 644 dports.fish      $(BUILD_DIR)/usr/share/fish/vendor_functions.d/$(PACKAGE).fish
	install -m 644 debian/copyright $(BUILD_DIR)/usr/share/doc/$(PACKAGE)/copyright
	gzip -9 -c debian/changelog > $(BUILD_DIR)/usr/share/doc/$(PACKAGE)/changelog.Debian.gz

	# Update version in the installed binary
	sed -i 's/^DPORTS_VERSION=.*/DPORTS_VERSION="$(VERSION)"/' $(BUILD_DIR)/usr/bin/$(PACKAGE)

	# Install DEBIAN metadata
	sed 's/^Version:.*/Version: $(VERSION)/' debian/control > $(BUILD_DIR)/DEBIAN/control
	install -m 755 debian/postinst  $(BUILD_DIR)/DEBIAN/postinst
	install -m 755 debian/prerm     $(BUILD_DIR)/DEBIAN/prerm

	# Build the package
	dpkg-deb --build --root-owner-group $(BUILD_DIR) $(DEB_NAME)
	@echo "Done: $(DEB_NAME)"

## Remove build artifacts
clean:
	rm -rf build/ *.deb
