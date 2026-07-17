#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT_DIR="${1:-${ROOT_DIR}/dist}"
ARCHIVE_NAME="FanControl-macos-arm64.zip"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"

/bin/mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd -P)"
WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/fan-control-package.XXXXXX")"
trap '/bin/rm -rf "${WORK_DIR}"' EXIT

cd "${ROOT_DIR}"
SWIFT_BUILD_ARGUMENTS=(
    -c release
    --arch arm64
    --disable-automatic-resolution
    -Xswiftc -gnone
)
/usr/bin/swift build "${SWIFT_BUILD_ARGUMENTS[@]}"
BIN_DIR="$(/usr/bin/swift build -c release --arch arm64 --show-bin-path)"
SOURCE_FINGERPRINT="$(
    {
        /bin/echo Package.swift
        /bin/echo Package.resolved
        /bin/echo Resources/Info.plist
        /usr/bin/find Sources -type f -name '*.swift' -print
    } | LC_ALL=C /usr/bin/sort | while IFS= read -r source_path; do
        /usr/bin/shasum -a 256 "${source_path}"
    done | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
)"

APP_DIR="${WORK_DIR}/FanControl.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
/bin/mkdir -p "${MACOS_DIR}"
/bin/cp -X Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
/bin/cp -X "${BIN_DIR}/FanControl" "${MACOS_DIR}/FanControl"
/bin/cp -X "${BIN_DIR}/FanHelper" "${MACOS_DIR}/FanHelper"
/bin/chmod 755 "${MACOS_DIR}/FanControl" "${MACOS_DIR}/FanHelper"
/usr/libexec/PlistBuddy \
    -c "Add :FanControlSourceSHA256 string ${SOURCE_FINGERPRINT}" \
    "${APP_DIR}/Contents/Info.plist"
# Do not publish build-host provenance metadata or AppleDouble sidecars.
/usr/bin/xattr -cr "${APP_DIR}"

/usr/bin/plutil -lint "${APP_DIR}/Contents/Info.plist"
for executable in FanControl FanHelper; do
    path="${MACOS_DIR}/${executable}"
    if [[ "$(/usr/bin/xcrun lipo -archs "${path}")" != "arm64" ]]; then
        echo "${executable} is not a thin arm64 executable" >&2
        exit 1
    fi
    if ! /usr/bin/xcrun vtool -show-build "${path}" | /usr/bin/grep -Eq 'minos 13\.0'; then
        echo "${executable} does not target macOS 13.0" >&2
        exit 1
    fi
    if /usr/bin/strings "${path}" |
        /usr/bin/grep -E '/Users/|/home/|/private/var/|\.build/.+\.o' >/dev/null; then
        echo "${executable} contains build-host paths" >&2
        exit 1
    fi
    # Swift linker signatures cover each Mach-O, not the hand-assembled outer bundle.
    /usr/bin/codesign --verify --strict --ignore-resources --verbose=2 "${path}"
done

ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${OUTPUT_DIR}/${CHECKSUM_NAME}"
/bin/rm -f "${ARCHIVE_PATH}" "${CHECKSUM_PATH}"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "${APP_DIR}" "${ARCHIVE_PATH}"
/usr/bin/unzip -tq "${ARCHIVE_PATH}"
(
    cd "${OUTPUT_DIR}"
    /usr/bin/shasum -a 256 "${ARCHIVE_NAME}" > "${CHECKSUM_NAME}"
)

echo "Packaged ${ARCHIVE_PATH}"
echo "Checksum ${CHECKSUM_PATH}"
