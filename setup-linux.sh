#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-linux.sh — prepare a Linux machine to build and run simple_harness.
#
# The project is dependency-free Swift, so the only real requirement is the
# Swift 6.2 toolchain (swift-tools-version:6.2) plus the small set of system
# libraries its Foundation needs. This script, run as root or with sudo:
#
#   1. installs the distro packages Swift needs (curl/xml2/sqlite/editline…)
#   2. installs the Swift toolchain if `swift` is missing or too old
#      (via swiftly, Swift's official version manager — no root needed after)
#   3. runs a build + selftest to prove the toolchain works
#
# Tested shapes: Ubuntu 22.04/24.04 (apt), Fedora (dnf), Arch (pacman).
# Usage:  ./setup-linux.sh          # install everything
#         ./setup-linux.sh --check  # only report what's missing
# ---------------------------------------------------------------------------
set -euo pipefail

SWIFT_MAJOR_REQUIRED=6
SWIFT_VERSION_TO_INSTALL="6.2.1"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

log()  { printf '\033[36m[setup]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[setup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || fail "run as root or install sudo"
    SUDO="sudo"
fi

# --- 1. detect the package manager -----------------------------------------
PKG=""
if command -v apt-get >/dev/null; then PKG=apt
elif command -v dnf >/dev/null; then PKG=dnf
elif command -v pacman >/dev/null; then PKG=pacman
else fail "unsupported distro: no apt-get/dnf/pacman. Install the Swift toolchain manually — https://www.swift.org/install/"
fi

# --- 2. distro packages the Swift toolchain needs at runtime ----------------
# (binutils/clang for the C shim target; curl/xml2/sqlite/editline/ncurses
# are what Swift's Foundation and the REPL link against; git for SPM + VCS)
APT_PACKAGES=(binutils git curl libcurl4-openssl-dev libxml2-dev libedit2
              libsqlite3-0 libncurses-dev libz3-dev zlib1g-dev libc6-dev
              pkg-config)
DNF_PACKAGES=(binutils git curl libcurl-devel libxml2-devel libedit-devel
              sqlite-devel ncurses-devel zlib-devel glibc-devel
              pkgconf-pkg-config)
PACMAN_PACKAGES=(binutils git curl curl libxml2 libedit sqlite ncurses zlib
                 pkgconf)

install_packages() {
    case "$PKG" in
        apt)    $SUDO apt-get update -qq && $SUDO apt-get install -y "${APT_PACKAGES[@]}" ;;
        dnf)    $SUDO dnf install -y "${DNF_PACKAGES[@]}" ;;
        pacman) $SUDO pacman -Sy --needed --noconfirm "${PACMAN_PACKAGES[@]}" ;;
    esac
}

# --- 3. swift presence / version --------------------------------------------
swift_ok() {
    command -v swift >/dev/null || return 1
    local version
    version=$(swift --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    [ -n "$version" ] || return 1
    [ "${version%%.*}" -ge "$SWIFT_MAJOR_REQUIRED" ]
}

# Map the running distro to Swift's published build (see swift.org/install).
# swift.org uses two names per platform: `slug` (the URL directory) and `full`
# (the tarball name). They differ for Ubuntu — the directory is "ubuntu2404"
# while the file is "swift-…-ubuntu24.04.tar.gz". The RHEL/CentOS/AlmaLinux/
# Rocky/Oracle 9 family is published as "ubi9" (Red Hat UBI 9); there is no
# "rhel9" download on swift.org.
detect_platform() {
    . /etc/os-release 2>/dev/null || true
    local id="${ID:-}" version="${VERSION_ID:-}"
    case "${id}:${version}" in
        rhel:9*|centos:9*|almalinux:9*|rocky:9*|ol:9*|ubi:9*)
            slug="ubi9"; full="ubi9" ;;
        ubuntu:24.*|pop:24.*)
            slug="ubuntu2404"; full="ubuntu24.04" ;;
        ubuntu:22.*|debian:*|pop:22.*)
            slug="ubuntu2204"; full="ubuntu22.04" ;;
        *)
            slug="ubuntu2404"; full="ubuntu24.04" ;;
    esac
}

# Move a Swift tree's `usr/` directory to the canonical $dest/usr, whichever
# layout the tarball used. Older tarballs unpack straight to usr/; newer ones
# (e.g. swift-6.2.1-RELEASE-ubi9) add a top-level version directory, so a naive
# extract lands at $dest/swift-6.2.1-RELEASE-ubi9/usr instead of $dest/usr.
normalize_swift() {
    local dest="$1" root="$2"
    [ "$root" = "$dest" ] && return 0
    log "Normalizing Swift layout → $dest/usr"
    $SUDO rm -rf "$dest/usr"
    $SUDO mv "$root/usr" "$dest/usr"
    $SUDO rmdir "$root" 2>/dev/null || true
}

install_swift() {
    local arch archsuffix slug full dest="$HOME/.swift"
    arch="$(uname -m)"
    # swift.org suffixes arm64 Linux builds with "-aarch64"; x86_64 has no suffix.
    archsuffix=""
    [ "$arch" = "aarch64" ] && archsuffix="-aarch64"
    detect_platform
    local url="https://download.swift.org/swift-${SWIFT_VERSION_TO_INSTALL}-release/${slug}${archsuffix}/swift-${SWIFT_VERSION_TO_INSTALL}-RELEASE/swift-${SWIFT_VERSION_TO_INSTALL}-RELEASE-${full}${archsuffix}.tar.gz"
    $SUDO mkdir -p "$dest"

    # Reuse a previously extracted tree (avoids re-downloading ~1 GB) and
    # normalize it if an earlier run left the nested tarball layout in place.
    if [ ! -x "$dest/usr/bin/swift" ]; then
        local existing
        existing="$(find "$dest" -maxdepth 4 -path '*/usr/bin/swift' -print -quit 2>/dev/null || true)"
        if [ -n "$existing" ]; then
            log "Reusing existing Swift tree at ${existing%/usr/bin/swift}"
            normalize_swift "$dest" "${existing%/usr/bin/swift}"
        fi
    fi

    if [ ! -x "$dest/usr/bin/swift" ]; then
        log "Downloading Swift $SWIFT_VERSION_TO_INSTALL (${slug}${archsuffix}) → $dest"
        local tmp
        tmp="$(mktemp -d)"
        curl -fL "$url" -o "$tmp/swift.tar.gz"
        $SUDO tar xzf "$tmp/swift.tar.gz" -C "$tmp"
        local swift_bin root
        swift_bin="$(find "$tmp" -maxdepth 4 -path '*/usr/bin/swift' -print -quit)"
        if [ -z "$swift_bin" ]; then
            rm -rf "$tmp"
            fail "downloaded Swift tarball does not contain usr/bin/swift"
        fi
        root="${swift_bin%/usr/bin/swift}"
        normalize_swift "$dest" "$root"
        rm -rf "$tmp"
    fi

    export PATH="$dest/usr/bin:$PATH"
    # Persist for future shells (bash and zsh both, whichever exists).
    local rc
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        grep -q '\.swift/usr/bin' "$rc" || \
            printf '\nexport PATH="$HOME/.swift/usr/bin:$PATH"\n' >> "$rc"
    done
}

if swift_ok; then
    log "Swift toolchain OK: $(swift --version | head -1)"
else
    if [ "$CHECK_ONLY" = 1 ]; then
        log "MISSING: Swift >= $SWIFT_MAJOR_REQUIRED toolchain (this script would install $SWIFT_VERSION_TO_INSTALL from swift.org)"
    else
        log "Installing Swift $SWIFT_VERSION_TO_INSTALL from swift.org (official tarball)"
        install_packages   # toolchain dependencies first
        install_swift
        swift_ok || fail "swift still not usable after install — check https://www.swift.org/install/"
        log "Installed: $(swift --version | head -1)"
    fi
fi

# --- 4. verify by building ---------------------------------------------------
if [ "$CHECK_ONLY" = 1 ]; then
    log "Check complete — install the items above, then re-run without --check."
    exit 0
fi

cd "$(dirname "$0")"
log "Building (first build takes a few minutes)…"
swift build
log "Running the offline selftest…"
swift run harness --selftest >/dev/null && log "selftest passed"

cat <<EOF

[setup] Done. To use the harness from a fresh shell:
    source ~/.bashrc                        # pick up the new PATH (or reopen the shell)
    swift run harness                       # or: swift build -c release
    ./.build/release/harness --help

Then create a ./.simple.h.conf next to where you run it (see README.md) and
export TYPESAFE_API_KEY=… if you want the naluri tool / pre-model gate.
EOF
