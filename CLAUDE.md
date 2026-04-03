# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
make          # compile and assemble .build/FanControl.app
make run      # build then open the app
make test     # run unit tests via `swift test` (no hardware required)
make clean    # remove .build/
```

`swift build` also works for the executable (without creating the .app bundle).
Target: `arm64-apple-macos13.0`. The app must **not** be sandboxed — sandboxing blocks `IOServiceOpen`.

## Architecture

```
Sources/
  FanControlKit/        ← library target (testable)
    SMC/
      SMCKit.swift      # IOKit interface: open/close AppleSMC, readKey, writeKey
      SMCKeys.swift     # Key name constants (FanKey.*, TempKey.*)
    Model/
      FanController.swift  # @ObservableObject: 3-s polling, fan writes, profile CRUD
      Profile.swift        # Codable FanProfile; persisted to ~/Library/Application Support/FanControl/
    UI/
      AppDelegate.swift    # NSStatusItem + NSPopover + Timer (public for cross-module access)
      MenuView.swift       # SwiftUI view inside the popover
  FanControl/           ← executable target (entry point only)
    FanControlApp.swift  # @main struct
Resources/
  Info.plist            # LSUIElement=YES (hide Dock icon)
Tests/
  FanControlKitTests/
    SMCDecodingTests.swift  # FPE2/SP78 encode-decode + four-char-code tests
    FanProfileTests.swift   # Codable round-trip + uniqueness tests
```

`FanControlKit` is a library so tests can `@testable import` it. `FanControl` is the thin executable that just calls `NSApplication.shared.run()`.

## SMC Key Protocol

All SMC I/O goes through `IOConnectCallStructMethod(connection, 2, ...)` — selector 2 is `kSMCHandleYPCEvent`. Sub-operation is chosen by `SMCParamStruct.data8`:

| data8 | Operation   |
|-------|-------------|
| 9     | getKeyInfo  |
| 5     | readKey     |
| 6     | writeKey    |

### Encodings
- **FPE2** (fan RPM): unsigned 14.2 fixed-point, big-endian. `raw = rpm × 4`.
- **SP78** (temperature °C): signed 7.8 fixed-point, big-endian. `°C = Int16(bitPattern: raw) / 256`.

### M2 Pro caveat
Apple Silicon may block writes to `F0Mn`/`F1Mn` (fan minimum floor), returning result code `0x85` (`kSMCNotWritable`). `FanController` catches `SMCError.writeNotPermitted` and surfaces `warningMessage` in the UI rather than crashing. Try writing and see what happens — some keys are still writable.

## Key Data Flow

1. `AppDelegate` fires a `Timer` every 3 s → calls `FanController.refresh()`
2. `refresh()` reads SMC keys → updates `@Published` properties
3. `AppDelegate` updates the `NSStatusItem` title from `cpuTemperature`
4. `MenuView` (SwiftUI inside `NSPopover`) observes `FanController` and re-renders automatically
5. Slider `onCommit` → `FanController.setFan0/1Speed()` → `SMCKit.writeFanRPM()`

## Tests

Tests cover pure-Swift logic only (encoding/decoding, JSON serialisation). Run with `make test` or `swift test`. The `swift-testing` package in `Package.swift` is required on CLT-only installs because the system `Testing.framework` lacks `lib_TestingInterop.dylib` (that ships with Xcode).
