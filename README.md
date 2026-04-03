# Mac (M2 Pro) Fan Control

> Because I don't wanna pay for Mac Fan Control.

> A native macOS menu bar app that monitors die temperature and controls fan speeds via direct SMC access.

> Fan control works on any Mac with fans. Temperature reading is currently keyed for **M2 Pro** — other chips will show `—°C` until their SMC key names are added to `SMCKeys.swift`.

> Maybe more support on future mac is coming, or not.

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
make install
```

Opens as `/Applications/FanControl.app`. On first launch it asks for your admin password once to install a privileged helper — fan control is silent after that.

## Uninstall

```bash
make uninstall
```

## Development

```bash
make          # build
make run      # build and run from .build/ (bypasses app bundle)
make test     # run unit tests (no hardware required)
make clean    # remove build artefacts
```

Enable the SMC dump button for debugging by setting `showSMCDump = true` in `Sources/FanControlKit/DebugFlags.swift`.
