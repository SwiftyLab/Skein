#!/bin/bash
# Turns the macOS archive from `make mac-archive` into a download: exports it
# signed with Developer ID, notarizes it with Apple, staples the ticket, and
# zips it as build/mac/Skein-<version>-<build>-macOS.zip. With RELEASE_TAG set,
# also attaches the zip to that GitHub release (the one `make release` made for
# the same version).
#
# Run through `make mac-release`, which passes the App Store Connect key
# (ASC_KEY_FILE, ASC_KEY_ID, ASC_ISSUER_ID) from Local.env for notarytool, so no
# Apple ID or app-specific password is needed. Signing needs a Developer ID
# Application certificate in the keychain.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ARCHIVE=build/Skein-macOS.xcarchive
OUT=build/mac
: "${ASC_KEY_FILE:?Set ASC_PRIVATE_KEY_PATH in Local.env}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID in Local.env}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID in Local.env}"
NOTARY=(--key "${ASC_KEY_FILE}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}")

APP="${OUT}/Skein.app"
# --notarize-only retries from an earlier export, e.g. after a network failure.
if [[ "${1:-}" == "--notarize-only" && -d "${APP}" ]]; then
    echo "==> reusing ${APP}"
else
    echo "==> exporting with Developer ID"
    rm -rf "${OUT}"
    # Signed with the keychain's Developer ID certificate (see ExportOptions-macOS.plist).
    xcodebuild -exportArchive -archivePath "${ARCHIVE}" -exportOptionsPlist ExportOptions-macOS.plist \
        -exportPath "${OUT}" -quiet
fi
codesign --verify --deep --strict "${APP}"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP}/Contents/Info.plist")
echo "    Skein ${version} (${build}), $(lipo -archs "${APP}/Contents/MacOS/Skein")"

# notarytool uploads to Apple's S3 bucket (notary-artifacts-prod.s3.amazonaws.com);
# a network that intercepts it fails here with a connect timeout.
echo "==> notarizing (usually a few minutes)"
ditto -c -k --keepParent "${APP}" "${OUT}/notarize.zip"
result=$(xcrun notarytool submit "${OUT}/notarize.zip" "${NOTARY[@]}" --wait --output-format json)
status=$(plutil -extract status raw - <<<"${result}" 2>/dev/null || echo "unknown")
id=$(plutil -extract id raw - <<<"${result}" 2>/dev/null || echo "")
if [[ "${status}" != "Accepted" ]]; then
    echo "Notarization ${status}." >&2
    # Apple's log says which file and why.
    [[ -n "${id}" ]] && xcrun notarytool log "${id}" "${NOTARY[@]}" >&2
    exit 1
fi
rm "${OUT}/notarize.zip"

echo "==> stapling"
# Lets Gatekeeper accept the app offline, without asking Apple.
xcrun stapler staple "${APP}"
spctl --assess --type execute "${APP}"

ZIP="${OUT}/Skein-${version}-${build}-macOS.zip"
ditto -c -k --keepParent "${APP}" "${ZIP}"
echo "    ${ZIP}"

if [[ -n "${RELEASE_TAG:-}" ]]; then
    echo "==> attaching to GitHub release ${RELEASE_TAG}"
    gh release upload "${RELEASE_TAG}" "${ZIP}" --clobber
fi
