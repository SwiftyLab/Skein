#!/usr/bin/env bash
# Builds OpenSSL as an xcframework for the platforms this project targets.
#
# libtorrent needs OpenSSL for HTTPS trackers and message-stream encryption, and
# does `#include <openssl/ssl.h>`. That rules out the popular prebuilt Swift
# packages, which ship framework-style headers (OpenSSL.framework/Headers) that
# do not satisfy that include. So we build it ourselves and lay the headers out
# at include/openssl, which is what libtorrent expects.
#
# Output: Vendor/openssl/OpenSSL.xcframework, containing one static library per
# platform with libssl and libcrypto merged together (an xcframework slice can
# only carry a single library).
#
# Takes a while — five Configure+make runs. Safe to re-run; it no-ops if the
# xcframework already exists. Pass --force to rebuild.
set -euo pipefail

OPENSSL_VERSION="3.5.8"          # 3.5 is the LTS branch
IOS_MIN="26.0"
MACOS_MIN="26.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${ROOT}/.build/openssl"
OUT="${ROOT}/Vendor/openssl"
XCFRAMEWORK="${OUT}/OpenSSL.xcframework"
JOBS="$(sysctl -n hw.ncpu)"

if [[ "${1:-}" != "--force" && -d "${XCFRAMEWORK}" ]]; then
    echo "${XCFRAMEWORK} already exists; pass --force to rebuild."
    exit 0
fi

mkdir -p "${WORK}"
SRC="${WORK}/openssl-${OPENSSL_VERSION}"

if [[ ! -d "${SRC}" ]]; then
    tarball="${WORK}/openssl-${OPENSSL_VERSION}.tar.gz"
    if [[ ! -f "${tarball}" ]]; then
        echo "==> downloading OpenSSL ${OPENSSL_VERSION}"
        curl -fsSL -o "${tarball}" \
            "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
    fi
    echo "==> extracting"
    tar xzf "${tarball}" -C "${WORK}"
fi

# Builds one architecture into its own prefix.
#   $1 arch label   $2 OpenSSL Configure target   $3 extra CFLAGS
build_arch() {
    local label="$1" target="$2" cflags="$3"
    local prefix="${WORK}/build/${label}"

    if [[ -f "${prefix}/lib/libssl.a" ]]; then
        echo "==> ${label}: already built"
        return
    fi

    echo "==> ${label}: configuring (${target})"
    local dir="${WORK}/src/${label}"
    rm -rf "${dir}"
    mkdir -p "${dir}"
    # Out-of-tree builds keep the five architectures from colliding.
    ( cd "${dir}" && "${SRC}/Configure" "${target}" \
        no-shared no-tests no-docs no-legacy \
        --prefix="${prefix}" \
        ${cflags} >/dev/null )

    echo "==> ${label}: building"
    make -C "${dir}" -j"${JOBS}" >/dev/null
    # install_dev installs headers and static libs, skipping apps and man pages.
    make -C "${dir}" install_dev >/dev/null
    echo "==> ${label}: done"
}

build_arch "macos-arm64"    "darwin64-arm64-cc"          "-mmacosx-version-min=${MACOS_MIN}"
build_arch "macos-x86_64"   "darwin64-x86_64-cc"         "-mmacosx-version-min=${MACOS_MIN}"
build_arch "ios-arm64"      "ios64-xcrun"                "-mios-version-min=${IOS_MIN}"
build_arch "iossim-arm64"   "iossimulator-arm64-xcrun"   "-mios-simulator-version-min=${IOS_MIN}"
build_arch "iossim-x86_64"  "iossimulator-x86_64-xcrun"  "-mios-simulator-version-min=${IOS_MIN}"

# Combines one or more architectures into a single platform slice: lipo the
# archs together, then merge libssl + libcrypto, since an xcframework slice can
# only hold one library.
#   $1 platform name   $2... arch labels
make_slice() {
    local platform="$1"; shift
    local slice="${WORK}/slices/${platform}"
    rm -rf "${slice}"
    mkdir -p "${slice}"

    for lib in libssl libcrypto; do
        local inputs=()
        for arch in "$@"; do inputs+=("${WORK}/build/${arch}/lib/${lib}.a"); done
        if [[ ${#inputs[@]} -eq 1 ]]; then
            cp "${inputs[0]}" "${slice}/${lib}.a"
        else
            lipo -create "${inputs[@]}" -output "${slice}/${lib}.a"
        fi
    done

    libtool -static -o "${slice}/libOpenSSL.a" "${slice}/libssl.a" "${slice}/libcrypto.a" 2>/dev/null
    rm -f "${slice}/libssl.a" "${slice}/libcrypto.a"

    # Headers come from the first arch. opensslconf.h is architecture-dependent
    # in principle; verify the archs agree rather than assuming it.
    cp -R "${WORK}/build/$1/include" "${slice}/include"
    for arch in "$@"; do
        if ! diff -q "${WORK}/build/$1/include/openssl/opensslconf.h" \
                     "${WORK}/build/${arch}/include/openssl/opensslconf.h" >/dev/null; then
            echo "ERROR: opensslconf.h differs between $1 and ${arch}." >&2
            echo "       A single header set cannot serve both; needs a dispatching header." >&2
            exit 1
        fi
    done
    echo "==> slice ${platform}: $(lipo -archs "${slice}/libOpenSSL.a")"
}

make_slice "macos"  "macos-arm64"  "macos-x86_64"
make_slice "ios"    "ios-arm64"
make_slice "iossim" "iossim-arm64" "iossim-x86_64"

echo "==> assembling xcframework"
rm -rf "${XCFRAMEWORK}"
mkdir -p "${OUT}"
xcodebuild -create-xcframework \
    -library "${WORK}/slices/macos/libOpenSSL.a"  -headers "${WORK}/slices/macos/include" \
    -library "${WORK}/slices/ios/libOpenSSL.a"    -headers "${WORK}/slices/ios/include" \
    -library "${WORK}/slices/iossim/libOpenSSL.a" -headers "${WORK}/slices/iossim/include" \
    -output "${XCFRAMEWORK}" >/dev/null

echo
echo "Built ${XCFRAMEWORK}"
