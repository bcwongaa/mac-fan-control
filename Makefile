APP      = FanControl
BUILD    = .build
BUNDLE   = $(BUILD)/$(APP).app
BINARY   = $(BUNDLE)/Contents/MacOS/$(APP)
PLIST    = $(BUNDLE)/Contents/Info.plist

SOURCES  = $(shell find Sources -name "*.swift")

.PHONY: all run clean test

# ── Build app bundle ──────────────────────────────────────────────────────────
# Target is the binary (not the bundle dir) so make correctly detects staleness.
all: $(BINARY)

$(BINARY): $(SOURCES) Resources/Info.plist
	swift build -c release
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@cp .build/release/FanControl $(BINARY)
	@cp Resources/Info.plist $(PLIST)
	@echo "Built $(BUNDLE)"

# ── Run in-place ──────────────────────────────────────────────────────────────
run: all
	open $(BUNDLE)

# ── Tests (no SMC hardware required) ─────────────────────────────────────────
test:
	swift test

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	@rm -rf $(BUILD)
	@echo "Cleaned"
