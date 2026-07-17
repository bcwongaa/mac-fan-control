APP      = FanControl
BUILD    = .build
BUNDLE   = /Applications/FanControl.app
MACOS    = $(BUNDLE)/Contents/MacOS

SOURCES  = $(shell find Sources -name "*.swift")

.PHONY: all run install install-prebuilt package uninstall clean test

# ── Build ─────────────────────────────────────────────────────────────────────
all:
	swift build -c release

# ── Run (binary directly — preserves linker code-signature for IOKit) ─────────
run: all
	$(BUILD)/release/FanControl

# ── Install to /Applications ──────────────────────────────────────────────────
# Copies the binary into a .app bundle WITHOUT re-codesigning, which preserves
# the linker-signed flag required for IOKit/SMC access on Apple Silicon.
install: all
	@mkdir -p $(MACOS)
	@cp Resources/Info.plist $(BUNDLE)/Contents/
	@cp $(BUILD)/release/FanControl $(MACOS)/
	@cp $(BUILD)/release/FanHelper  $(MACOS)/
	@echo "Installed: $(BUNDLE)"
	@echo "Open with: open $(BUNDLE)"

# Installs the committed arm64 package without requiring Xcode or Swift.
install-prebuilt:
	@./install.sh

# Builds the distributable app archive and SHA-256 checksum in dist/.
package:
	@./Scripts/package-release.sh

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall:
	@rm -rf $(BUNDLE)
	@rm -f  /usr/local/bin/FanHelper \
		/Library/PrivilegedHelperTools/com.local.FanControl.FanHelper \
		/etc/sudoers.d/fan-control
	@echo "Uninstalled FanControl"

# ── Tests (no SMC hardware required) ─────────────────────────────────────────
test:
	swift test

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	@rm -rf $(BUILD)
	@echo "Cleaned"
