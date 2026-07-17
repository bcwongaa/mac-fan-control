#!/bin/bash

set -euo pipefail

REPOSITORY="bcwongaa/mac-fan-control"
ARCHIVE_NAME="FanControl-macos-arm64.zip"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"
INSTALL_DIR="${FANCONTROL_INSTALL_DIR:-/Applications}"

if [[ -z "${INSTALL_DIR}" || "${INSTALL_DIR}" == "/" ]]; then
    echo "Refusing unsafe installation directory: ${INSTALL_DIR}" >&2
    exit 1
fi
if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
    echo "FanControl requires an Apple Silicon Mac" >&2
    exit 1
fi
MACOS_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{ print $1 }')"
if [[ ! "${MACOS_MAJOR}" =~ ^[0-9]+$ || "${MACOS_MAJOR}" -lt 13 ]]; then
    echo "FanControl requires macOS 13 or newer" >&2
    exit 1
fi

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd -P)"
DIST_DIR="${FANCONTROL_DIST_DIR:-${SCRIPT_DIR}/dist}"
WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/fan-control-install.XXXXXX")"
trap '/bin/rm -rf "${WORK_DIR}"' EXIT

ARCHIVE_PATH="${WORK_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${WORK_DIR}/${CHECKSUM_NAME}"

copy_local_package() {
    /bin/cp "${DIST_DIR}/${ARCHIVE_NAME}" "${ARCHIVE_PATH}"
    /bin/cp "${DIST_DIR}/${CHECKSUM_NAME}" "${CHECKSUM_PATH}"
}

download_package() {
    local base_url="$1"
    /usr/bin/curl \
        --proto '=https' \
        --proto-redir '=https' \
        --tlsv1.2 \
        --fail \
        --location \
        --retry 3 \
        --connect-timeout 10 \
        --max-time 300 \
        --output "${ARCHIVE_PATH}" \
        "${base_url}/${ARCHIVE_NAME}" &&
    /usr/bin/curl \
        --proto '=https' \
        --proto-redir '=https' \
        --tlsv1.2 \
        --fail \
        --location \
        --retry 3 \
        --connect-timeout 10 \
        --max-time 300 \
        --output "${CHECKSUM_PATH}" \
        "${base_url}/${CHECKSUM_NAME}"
}

PACKAGE_ORIGIN="local"
if [[ -f "${DIST_DIR}/${ARCHIVE_NAME}" && -f "${DIST_DIR}/${CHECKSUM_NAME}" ]]; then
    copy_local_package
else
    PACKAGE_ORIGIN="download"
    requested_version="${FANCONTROL_VERSION:-latest}"
    if [[ "${requested_version}" == "latest" ]]; then
        release_url="https://github.com/${REPOSITORY}/releases/latest/download"
        if ! download_package "${release_url}"; then
            echo "No published release found; using the prebuilt package from main." >&2
            raw_url="https://raw.githubusercontent.com/${REPOSITORY}/main/dist"
            download_package "${raw_url}"
        fi
    else
        if [[ ! "${requested_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "FANCONTROL_VERSION must be latest or vMAJOR.MINOR.PATCH" >&2
            exit 1
        fi
        release_url="https://github.com/${REPOSITORY}/releases/download/${requested_version}"
        download_package "${release_url}"
    fi
fi

expected_checksum="$(
    /usr/bin/awk -v archive="${ARCHIVE_NAME}" '$2 == archive { print $1; exit }' \
        "${CHECKSUM_PATH}"
)"
if [[ ! "${expected_checksum}" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "Invalid checksum file" >&2
    exit 1
fi
actual_checksum="$(/usr/bin/shasum -a 256 "${ARCHIVE_PATH}" | /usr/bin/awk '{ print $1 }')"
if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
    echo "FanControl package checksum mismatch" >&2
    exit 1
fi
if [[ "${PACKAGE_ORIGIN}" == "download" ]]; then
    echo "Downloaded build is ad-hoc signed and is not Apple-notarized." >&2
    echo "The SHA-256 checksum protects transfer integrity, not publisher identity." >&2
fi

ARCHIVE_SIZE="$(/usr/bin/stat -f '%z' "${ARCHIVE_PATH}")"
UNCOMPRESSED_SIZE="$(/usr/bin/unzip -l "${ARCHIVE_PATH}" | /usr/bin/awk 'END { print $1 }')"
if [[ ! "${ARCHIVE_SIZE}" =~ ^[0-9]+$ || "${ARCHIVE_SIZE}" -gt 10485760 ||
      ! "${UNCOMPRESSED_SIZE}" =~ ^[0-9]+$ || "${UNCOMPRESSED_SIZE}" -gt 10485760 ]]; then
    echo "FanControl package exceeds the 10 MiB safety limit" >&2
    exit 1
fi

EXTRACT_DIR="${WORK_DIR}/extracted"
/bin/mkdir -p "${EXTRACT_DIR}"
EXPECTED_ARCHIVE_ENTRIES="$(
    /usr/bin/printf '%s\n' \
        'FanControl.app/' \
        'FanControl.app/Contents/' \
        'FanControl.app/Contents/Info.plist' \
        'FanControl.app/Contents/MacOS/' \
        'FanControl.app/Contents/MacOS/FanControl' \
        'FanControl.app/Contents/MacOS/FanHelper' | LC_ALL=C /usr/bin/sort
)"
ACTUAL_ARCHIVE_ENTRIES="$(/usr/bin/unzip -Z1 "${ARCHIVE_PATH}" | LC_ALL=C /usr/bin/sort)"
if [[ "${ACTUAL_ARCHIVE_ENTRIES}" != "${EXPECTED_ARCHIVE_ENTRIES}" ]]; then
    echo "FanControl package contains unexpected files" >&2
    exit 1
fi
/usr/bin/ditto -x -k "${ARCHIVE_PATH}" "${EXTRACT_DIR}"
APP_SOURCE="${EXTRACT_DIR}/FanControl.app"

validate_app_bundle() {
    local app_path="$1"
    local info_plist="${app_path}/Contents/Info.plist"
    local macos_dir="${app_path}/Contents/MacOS"
    local source_fingerprint
    local executable
    local path

    if [[ ! -d "${app_path}" || -L "${app_path}" ||
          ! -d "${app_path}/Contents" || -L "${app_path}/Contents" ||
          ! -d "${macos_dir}" || -L "${macos_dir}" ||
          ! -f "${info_plist}" || -L "${info_plist}" ]]; then
        echo "Package does not contain a regular FanControl.app bundle" >&2
        return 1
    fi

    /usr/bin/plutil -lint "${info_plist}" >/dev/null
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${info_plist}")" != "FanControl" ||
          "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}")" != "com.local.FanControl" ||
          "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "${info_plist}")" != "APPL" ||
          "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${info_plist}")" != "13.0" ]]; then
        echo "Package contains unexpected application metadata" >&2
        return 1
    fi
    source_fingerprint="$(
        /usr/libexec/PlistBuddy -c 'Print :FanControlSourceSHA256' "${info_plist}"
    )"
    if [[ ! "${source_fingerprint}" =~ ^[[:xdigit:]]{64}$ ]]; then
        echo "Package source fingerprint is invalid" >&2
        return 1
    fi

    for executable in FanControl FanHelper; do
        path="${macos_dir}/${executable}"
        if [[ ! -f "${path}" || -L "${path}" || ! -x "${path}" ]]; then
            echo "Package contains an invalid ${executable} executable" >&2
            return 1
        fi
        if ! /usr/bin/file "${path}" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64'; then
            echo "Package contains a non-arm64 ${executable} executable" >&2
            return 1
        fi
        # Swift linker signatures do not seal the hand-assembled outer app bundle.
        /usr/bin/codesign --verify --strict --ignore-resources "${path}"
    done
}

validate_app_bundle "${APP_SOURCE}"

DESTINATION="${INSTALL_DIR}/FanControl.app"
STAGING="${INSTALL_DIR}/.FanControl.app.installing.$$"

if [[ "${INSTALL_DIR}" == "/Applications" ]] && /usr/bin/pgrep -x FanControl >/dev/null; then
    /usr/bin/osascript -e 'tell application id "com.local.FanControl" to quit' >/dev/null
    for _ in {1..80}; do
        if ! /usr/bin/pgrep -x FanControl >/dev/null; then
            break
        fi
        /bin/sleep 0.1
    done
    if /usr/bin/pgrep -x FanControl >/dev/null; then
        echo "FanControl is still running; quit it and retry installation" >&2
        exit 1
    fi
fi

if /bin/mkdir -p "${INSTALL_DIR}" 2>/dev/null && [[ -w "${INSTALL_DIR}" ]]; then
    /bin/rm -rf "${STAGING}"
    /usr/bin/ditto "${APP_SOURCE}" "${STAGING}"
    /bin/rm -rf "${DESTINATION}"
    /bin/mv "${STAGING}" "${DESTINATION}"
else
    /usr/bin/osascript - "${APP_SOURCE}" "${INSTALL_DIR}" "${DESTINATION}" "${STAGING}" <<'APPLESCRIPT'
on run argv
    set sourcePath to item 1 of argv
    set installDirectory to item 2 of argv
    set destinationPath to item 3 of argv
    set stagingPath to item 4 of argv
    set commandText to "/bin/mkdir -p " & quoted form of installDirectory
    set commandText to commandText & " && /bin/rm -rf " & quoted form of stagingPath
    set commandText to commandText & " && /usr/bin/ditto " & quoted form of sourcePath
    set commandText to commandText & " " & quoted form of stagingPath
    set commandText to commandText & " && /bin/rm -rf " & quoted form of destinationPath
    set commandText to commandText & " && /bin/mv " & quoted form of stagingPath
    set commandText to commandText & " " & quoted form of destinationPath
    do shell script commandText with administrator privileges
end run
APPLESCRIPT
fi

validate_app_bundle "${DESTINATION}"
for relative_path in \
    Contents/Info.plist \
    Contents/MacOS/FanControl \
    Contents/MacOS/FanHelper; do
    if ! /usr/bin/cmp -s "${APP_SOURCE}/${relative_path}" "${DESTINATION}/${relative_path}"; then
        echo "Installed FanControl differs from the verified package" >&2
        exit 1
    fi
done

echo "Installed ${DESTINATION}"
echo "The first launch will request administrator approval for the fan helper."
if [[ "${FANCONTROL_NO_OPEN:-0}" != "1" ]]; then
    /usr/bin/open "${DESTINATION}"
fi
