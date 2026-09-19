#!/usr/bin/env bash
# Fetches the third-party sources the package needs but does not vendor in git.
#
#   - libtorrent  : git submodule, pinned to v2.0.14
#   - Boost 1.92  : headers only (~184 MB), too large to commit
#
# Safe to re-run; each step is skipped if already present.
set -euo pipefail

BOOST_VERSION="1.92.0"
BOOST_UNDERSCORE="${BOOST_VERSION//./_}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOST_DIR="${ROOT}/Vendor/boost"

echo "==> libtorrent submodule"
if [[ -f "${ROOT}/Vendor/libtorrent/CMakeLists.txt" ]]; then
    echo "    already present"
else
    git -C "${ROOT}" submodule update --init --depth 1 Vendor/libtorrent
fi

echo "==> libtorrent's try_signal dependency"
if [[ -f "${ROOT}/Vendor/libtorrent/deps/try_signal/try_signal.cpp" ]]; then
    echo "    already present"
else
    git -C "${ROOT}/Vendor/libtorrent" submodule update --init --depth 1 deps/try_signal
fi

echo "==> Boost ${BOOST_VERSION} headers"
if [[ -d "${BOOST_DIR}/boost" ]]; then
    echo "    already present"
else
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    url="https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_UNDERSCORE}.tar.gz"
    echo "    downloading ${url}"
    curl -fsSL -o "${tmp}/boost.tar.gz" "${url}"
    echo "    extracting headers"
    tar xzf "${tmp}/boost.tar.gz" -C "${tmp}" "boost_${BOOST_UNDERSCORE}/boost"
    mkdir -p "${BOOST_DIR}"
    mv "${tmp}/boost_${BOOST_UNDERSCORE}/boost" "${BOOST_DIR}/boost"
fi

echo
echo "Done. Build with:  swift build"
