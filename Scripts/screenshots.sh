#!/bin/bash
# Captures the App Store Connect screenshots on the simulators Apple requires,
# using the app's screenshot mode (fixed content, engine never started; see
# App/Sources/Shared/ScreenshotMode.swift).
#
# Writes AppStore/screenshots/<iphone|ipad>/<n>-<screen>.png, which
# `make screenshots-upload` sends to App Store Connect.
#
# Override the simulators with IPHONE_SIM / IPAD_SIM. They must be a 6.9" iPhone
# and a 13" iPad, the two sizes App Store Connect requires.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

IPHONE_SIM="${IPHONE_SIM:-iPhone 18 Pro Max}"
IPAD_SIM="${IPAD_SIM:-iPad Pro 13-inch (M5)}"
# From Local.env, which `make screenshots` exports.
BUNDLE_ID="${TUIST_BUNDLE_ID:?Set TUIST_BUNDLE_ID in Local.env, or run this through make screenshots}"
OUT=AppStore/screenshots
DERIVED=.build/screenshots-dd
APP="${DERIVED}/Build/Products/Debug-iphonesimulator/Skein.app"
# In the order they appear on the listing: the list alone, then each sheet over it.
SCREENS=(list add settings)

echo "==> building for the simulator"
# Signed locally ("-"), so no account is needed. Debug, because screenshot
# mode is compiled out of release builds.
xcodebuild -workspace Skein.xcworkspace -scheme Skein -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "${DERIVED}" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    build -quiet

capture() {
    local kind="$1" name="$2"
    # Exact name match, so "iPhone 18 Pro" doesn't pick "iPhone 18 Pro Max".
    local udid
    udid=$(xcrun simctl list devices available | grep -m1 -F "    ${name} (" | grep -oE '[0-9A-F-]{36}' || true)
    [[ -n "${udid}" ]] || { echo "No available simulator named \"${name}\"." >&2; exit 1; }

    echo "==> ${kind}: ${name}"
    local booted=0
    if ! xcrun simctl list devices | grep -F "${udid}" | grep -q Booted; then
        xcrun simctl boot "${udid}"
        booted=1
    fi
    xcrun simctl bootstatus "${udid}" -b >/dev/null
    # Apple's marketing status bar: 9:41, full battery and signal.
    xcrun simctl status_bar "${udid}" override --time 9:41 --dataNetwork wifi --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    xcrun simctl ui "${udid}" appearance light
    xcrun simctl install "${udid}" "${APP}"

    # The first launch after a cold boot can take several seconds to draw, and
    # captures black until it does.
    xcrun simctl launch "${udid}" "${BUNDLE_ID}" -screenshots YES >/dev/null
    sleep 10

    rm -rf "${OUT:?}/${kind}"
    mkdir -p "${OUT}/${kind}"
    local index=1 screen
    for screen in "${SCREENS[@]}"; do
        xcrun simctl terminate "${udid}" "${BUNDLE_ID}" 2>/dev/null || true
        xcrun simctl launch "${udid}" "${BUNDLE_ID}" -screenshots YES -screenshotScreen "${screen}" >/dev/null
        # Long enough for the sheet to finish presenting.
        sleep 4
        xcrun simctl io "${udid}" screenshot --type=png "${OUT}/${kind}/${index}-${screen}.png" >/dev/null 2>&1
        echo "    ${OUT}/${kind}/${index}-${screen}.png"
        index=$((index + 1))
    done

    xcrun simctl terminate "${udid}" "${BUNDLE_ID}" 2>/dev/null || true
    xcrun simctl status_bar "${udid}" clear
    [[ ${booted} -eq 1 ]] && xcrun simctl shutdown "${udid}"
    return 0
}

capture iphone "${IPHONE_SIM}"
capture ipad "${IPAD_SIM}"
echo "==> done; check them, then \`make screenshots-upload\`"
