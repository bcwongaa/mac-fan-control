APP      = FanControl
BUILD    = .build

SOURCES  = $(shell find Sources -name "*.swift")

.PHONY: all run clean test

# ── Build ─────────────────────────────────────────────────────────────────────
all:
	swift build -c release

# ── Run (binary directly — preserves linker code-signature for IOKit) ─────────
run: all
	$(BUILD)/release/FanControl

# ── Tests (no SMC hardware required) ─────────────────────────────────────────
test:
	swift test

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	@rm -rf $(BUILD)
	@echo "Cleaned"
