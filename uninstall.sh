#!/bin/bash

set -euo pipefail

APP_PATH="/Applications/FanControl.app"
HELPER_PATH="/Library/PrivilegedHelperTools/com.local.FanControl.FanHelper"
SUDOERS_PATH="/etc/sudoers.d/fan-control"
LEGACY_HELPER_PATH="/usr/local/bin/FanHelper"
HELPER_PROCESS_PATTERN='/Library/PrivilegedHelperTools/com[.]local[.]FanControl[.]FanHelper serve([[:space:]]|$)'

helper_process_is_running() {
    /usr/bin/pgrep -f "${HELPER_PROCESS_PATTERN}" >/dev/null 2>&1
}

if [[ "${FANCONTROL_UNINSTALL_DRY_RUN:-0}" == "1" ]]; then
    echo "Would restore automatic fan control and remove:"
    printf '  %s\n' \
        "${APP_PATH}" \
        "${HELPER_PATH}" \
        "${SUDOERS_PATH}" \
        "${LEGACY_HELPER_PATH}"
    exit 0
fi

if /usr/bin/pgrep -x FanControl >/dev/null; then
    if ! /usr/bin/osascript \
        -e 'tell application id "com.local.FanControl" to quit' >/dev/null; then
        echo "Could not ask FanControl to quit; quit it manually and retry" >&2
        exit 1
    fi
    for _ in {1..80}; do
        if ! /usr/bin/pgrep -x FanControl >/dev/null; then
            break
        fi
        /bin/sleep 0.1
    done
    if /usr/bin/pgrep -x FanControl >/dev/null; then
        echo "FanControl is still running; quit it and retry" >&2
        exit 1
    fi
fi

# Never race a leased helper with a second SMC connection.
for _ in {1..150}; do
    if ! helper_process_is_running; then
        break
    fi
    /bin/sleep 0.1
done
if helper_process_is_running; then
    echo "FanHelper is still active; wait for its lease to expire and retry" >&2
    exit 1
fi

uninstall_failed=0
if apple_output="$(
    /usr/bin/osascript - \
        "${APP_PATH}" \
        "${HELPER_PATH}" \
        "${SUDOERS_PATH}" \
        "${LEGACY_HELPER_PATH}" 2>&1 <<'APPLESCRIPT'
on run argv
    set appPath to item 1 of argv
    set helperPath to item 2 of argv
    set sudoersPath to item 3 of argv
    set legacyHelperPath to item 4 of argv

    set restoreFans to "if [ -e " & quoted form of helperPath
    set restoreFans to restoreFans & " ] && [ ! -x " & quoted form of helperPath
    set restoreFans to restoreFans & " ]; then /bin/echo 'Installed helper is not executable' >&2; exit 1; fi; if [ -x "
    set restoreFans to restoreFans & quoted form of helperPath & " ]; then "
    set restoreFans to restoreFans & "/usr/bin/printf 'auto\\nshutdown\\n' | "
    set restoreFans to restoreFans & quoted form of helperPath
    set restoreFans to restoreFans & " serve >/dev/null || exit 1; "
    set restoreFans to restoreFans & "elif [ -e " & quoted form of legacyHelperPath
    set restoreFans to restoreFans & " ] && [ ! -x " & quoted form of legacyHelperPath
    set restoreFans to restoreFans & " ]; then /bin/echo 'Legacy helper is not executable' >&2; exit 1; elif [ -x "
    set restoreFans to restoreFans & quoted form of legacyHelperPath & " ]; then "
    set restoreFans to restoreFans & quoted form of legacyHelperPath
    set restoreFans to restoreFans & " auto >/dev/null || exit 1; fi"
    set removeApp to "/bin/rm -rf " & quoted form of appPath
    set removeFiles to "/bin/rm -f " & quoted form of helperPath
    set removeFiles to removeFiles & " " & quoted form of sudoersPath
    set removeFiles to removeFiles & " " & quoted form of legacyHelperPath
    do shell script restoreFans & " && " & removeApp & " && " & removeFiles with administrator privileges
end run
APPLESCRIPT
)"; then
    :
else
    uninstall_failed=1
    echo "Uninstall stopped because automatic recovery or privileged removal failed." >&2
    if [[ -n "${apple_output}" ]]; then
        printf '%s\n' "${apple_output}" >&2
    fi
fi

remaining_paths=0
for path in "${APP_PATH}" "${HELPER_PATH}" "${SUDOERS_PATH}" "${LEGACY_HELPER_PATH}"; do
    if [[ -e "${path}" || -L "${path}" ]]; then
        echo "Still present: ${path}" >&2
        remaining_paths=1
    fi
done

if [[ "${uninstall_failed}" -ne 0 || "${remaining_paths}" -ne 0 ]]; then
    exit 1
fi

echo "FanControl was removed. Any installed helper completed an automatic fan reset first."
