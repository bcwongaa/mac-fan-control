# FanControl for Apple Silicon MacBook Pro

[![CI](https://github.com/bcwongaa/mac-fan-control/actions/workflows/ci.yml/badge.svg)](https://github.com/bcwongaa/mac-fan-control/actions/workflows/ci.yml)

> Because I don't wanna pay for Mac Fan Control.

A native macOS menu bar app that monitors die temperature and controls fan speeds through the SMC.

## Supported hardware

FanControl is designed for fan-equipped Apple Silicon MacBook Pro models running macOS 13 or newer:

- M1 Pro and M1 Max
- M2, M2 Pro, and M2 Max
- M3, M3 Pro, and M3 Max
- M4, M4 Pro, and M4 Max
- M5, M5 Pro, and M5 Max

The one-fan 13-inch M2 and base-chip 14-inch models are handled alongside the two-fan 14-inch and 16-inch Pro/Max models. Fan layouts are detected at runtime. Fanless MacBook Air models do not expose manual fan controls.

Physical fan-control testing has been done on 14-inch M2 Pro, base M4 (one fan), and M5 Pro MacBook Pros. Support for the other models is based on Apple repair information, physical SMC reports from the community, runtime probing, and hardware-independent regression tests. Hardware reports and fixes are welcome.

## Read this before installing

This app performs low-level SMC writes and installs a root-owned helper plus a narrowly scoped sudoers rule on first launch. Incorrect fan settings can affect temperature, performance, component life, and system stability.

The prebuilt app is open source, ad-hoc signed, and **not notarized by Apple**. Review the source and installer if this matters to you. The checksum and ad-hoc signatures detect corruption and unexpected package contents, but they do not authenticate the publisher; for higher assurance, build from source. Use it entirely at your own risk; the project is provided without warranty under the MIT License.

## Install the prebuilt app

Xcode and Swift are not required. Download the installer, inspect it if desired, and run it:

```bash
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location \
  https://raw.githubusercontent.com/bcwongaa/mac-fan-control/main/install.sh \
  --output /tmp/fancontrol-install.sh
bash /tmp/fancontrol-install.sh
```

If you already cloned the repository:

```bash
./install.sh
```

The standalone installer tries the latest [GitHub Release](https://github.com/bcwongaa/mac-fan-control/releases/latest), then falls back to the prebuilt package committed on `main` if that download fails. When run from a checkout, it uses that checkout's committed package. It verifies the SHA-256 checksum, architecture, bundle contents, and embedded executable signatures before installing `/Applications/FanControl.app`.

On initial installation—and again when an update changes the helper—macOS asks for administrator approval so FanControl can install its privileged helper. The helper attempts to restore automatic fan control after its lease expires, when the app quits, and during recovery from a lost session.

### Gatekeeper

Because the app is not notarized, macOS may refuse the first launch. After attempting to open it, go to **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**, authenticate, then confirm **Open**. Do not disable Gatekeeper globally. See [Apple's current instructions for opening an app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

## Build from source

Install Apple's Command Line Tools and build locally:

```bash
xcode-select --install
make install
open /Applications/FanControl.app
```

## Uninstall

Select **Auto** in FanControl and confirm that automatic control is restored, then disable **Launch at Login**. Download and inspect the standalone uninstaller before running it: it requests administrator approval, quits the app, waits for the leased helper to exit, requires any installed helper to report a successful automatic reset, and removes the app, helper, and sudoers rule.

```bash
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location \
  https://raw.githubusercontent.com/bcwongaa/mac-fan-control/main/uninstall.sh \
  --output /tmp/fancontrol-uninstall.sh
bash /tmp/fancontrol-uninstall.sh
```

From a repository checkout, run `./uninstall.sh` instead.

Saved profiles under `~/Library/Application Support/FanControl` are retained so a later reinstall can reuse them.

## How fan control works

The helper probes each Mac at runtime instead of hard-coding per-model behavior:

- **Fan layout** comes from `FNum`, and each fan's range from `F<n>Mn`/`F<n>Mx`.
- **Manual mode** is entered by writing `1` to `F<n>Md` (or the lowercase `F<n>md` alias), then the target RPM to `F<n>Tg`, encoded in the key's reported data type. The helper confirms the target was retained and that the measured `F<n>Ac` RPM responds.
- **The `Ftst` unlock** is used when the SMC rejects a direct mode write or the fan ignores the target. On the tested M4, `thermalmonitord` releases the fan only after `Ftst=1` has been held for about 5 seconds, so the helper keeps retrying the mode write for up to about 10 seconds. The first slider change can therefore take several seconds to take effect; later changes are immediate while the fan stays in manual mode.
- **Automatic control** is restored by writing `0` to each mode key and then clearing `Ftst`. A mode value of `0` or `3` counts as automatic.

Hardware quirks handled on M4 (observed on a 14-inch M4, `Mac16,1`):

- Every `F0Md` write, including writing `0` while the fan is already automatic, fails with SMC result `0x82` unless `Ftst` reads `1`. The helper treats a rejected write as success when the mode already reads automatic.
- Accepted `Ftst` and `F0Tg` writes can take about half a second to read back; until then the SMC reports the previous value (for `F0Tg`, often the minimum RPM). The helper polls for up to 2 seconds before reporting a write as not retained.

## Troubleshooting

- **`F0Md: write result=0x82`, `Ftst write was not retained`, or `F0Tg read back 2317.0 RPM, expected …`**: these errors come from helper builds older than 0.1.1 running on M4-class SMCs. Update to 0.1.1 or newer by rerunning the installer (it prefers the latest GitHub Release, so check that the release is 0.1.1 or newer) or by running `make install` from a checkout. FanControl asks for administrator approval and replaces the privileged helper on its next launch.
- **Collecting a hardware report**: enable the read-only SMC dump (see [Development](#development)) and include its output, your model identifier (`sysctl -n hw.model`), and the exact error text in an issue.

## Development

```bash
make          # build
make run      # build and run from .build/
make test     # run unit tests without SMC hardware
make package  # rebuild the arm64 release archive and checksum
make clean    # remove build artifacts
```

Enable the read-only SMC dump button for debugging by setting `showSMCDump = true` in `Sources/FanControlKit/DebugFlags.swift`.
