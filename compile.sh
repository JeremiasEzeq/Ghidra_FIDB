#!/bin/bash

# compile.sh - Download and compile a library
# Usage: ./compile.sh <library> <version> [arch] [output_base_dir]
#
# Supported libraries: openssl
# Supported architectures: x86_64, aarch64, arm, mips64el
# Example: ./compile.sh openssl 3.5.0               (default: x86_64)
#          ./compile.sh openssl 3.5.0 aarch64

set -euo pipefail

# ─── Helpers ────────────────────────────────────────────────────────────────

log()   { echo "[$(date '+%H:%M:%S')] $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }
check() { command -v "$1" &>/dev/null || die "Required tool not found: $1"; }

# ─── Args ───────────────────────────────────────────────────────────────────

if [[ $# -lt 2 || $# -gt 4 ]]; then
    die "Usage: ${0} <library> <version> [arch] [output_base_dir]"
fi

library="${1}"
version="${2}"
arch="${3:-x86_64}"
base_dir="${4:-output}"

# ─── Check dependencies ─────────────────────────────────────────────────────

check curl
check tar
check make
check envsubst

# ─── Architecture mapping ──────────────────────────────────────────────────

setup_toolchain() {
    case "${1}" in
        x86_64)  ;;
        aarch64)
            export CC=aarch64-linux-gnu-gcc
            export AR=aarch64-linux-gnu-ar
            export RANLIB=aarch64-linux-gnu-ranlib
            ;;
        arm)
            export CC=arm-linux-gnueabihf-gcc
            export AR=arm-linux-gnueabihf-ar
            export RANLIB=arm-linux-gnueabihf-ranlib
            ;;
        mips64el)
            export CC=mips64el-linux-gnuabi64-gcc
            export AR=mips64el-linux-gnuabi64-ar
            export RANLIB=mips64el-linux-gnuabi64-ranlib
            ;;
        *)
            die "Unsupported architecture: '${1}'. Supported: x86_64, aarch64, arm, mips64el"
            ;;
    esac
}

config_target_of() {
    case "${1}" in
        x86_64)   echo "linux-x86_64"   ;;
        aarch64)  echo "linux-aarch64"  ;;
        arm)      echo "linux-armv4"    ;;
        mips64el) echo "linux-mips64"   ;;
    esac
}

# ─── Directory layout ───────────────────────────────────────────────────────
#
# output/
# ├── sources/   - downloaded tarballs
# ├── bin/       - compiled binaries, structured for Ghidra import
# │   └── <library>/linux/<library>/<version>/  ← the binary goes here
# ├── projects/  - Ghidra project files
# ├── logs/      - all logs
# └── fid_files/ - final .fidb output

src_dir="${base_dir}/sources"
bin_dir="${base_dir}/bin"
projects_dir="${base_dir}/projects"
logs_dir="${base_dir}/logs"

mkdir -p "${src_dir}" "${bin_dir}" "${projects_dir}" "${logs_dir}"

# ─── Library-specific config ────────────────────────────────────────────────

setup_library() {
    case "${library}" in
        openssl)
            tarball_url="https://github.com/openssl/openssl/releases/download/openssl-${version}/openssl-${version}.tar.gz"
            tarball_name="openssl-${version}.tar.gz"
            src_subdir="openssl-${version}"
            variant="linux"
            name="openssl"
            ;;
        *)
            die "Unsupported library: '${library}'. Supported: openssl"
            ;;
    esac

    # Where the binary will live for Ghidra import
    binary_dir="${bin_dir}/${library}/${variant}/${name}"
    mkdir -p "${binary_dir}"
}

# ─── Compile functions ───────────────────────────────────────────────────────

compile_openssl() {
    local config_target="$1"
    local compile_log="$(pwd)/${logs_dir}/${library}-${arch}-compile.log"
    local src_path="${src_dir}/${src_subdir}"

    log "Configuring OpenSSL ${version} for ${arch} (target: ${config_target})..."
    pushd "${src_path}" > /dev/null
        ./Configure -static no-tests "${config_target}" >> "${compile_log}" 2>&1

        log "Compiling OpenSSL ${version} for ${arch}..."
        make -j"$(nproc)" >> "${compile_log}" 2>&1
    popd > /dev/null
}

# ─── Pipeline steps ─────────────────────────────────────────────────────────

step_download() {
    local tarball="${src_dir}/${tarball_name}"

    if [[ -f "${tarball}" ]]; then
        log "Tarball already downloaded, skipping: ${tarball_name}"
    else
        log "Downloading ${library} ${version} from ${tarball_url}..."
        curl -L --fail --progress-bar -o "${tarball}" "${tarball_url}" \
            || die "Download failed"
    fi

    if [[ ! -d "${src_dir}/${src_subdir}" ]]; then
        log "Extracting ${tarball_name}..."
        tar -xzf "${tarball}" -C "${src_dir}" \
            || die "Extraction failed"
    else
        log "Source already extracted, skipping."
    fi
}

step_compile() {
    local src_path="${src_dir}/${src_subdir}"
    local arch_marker="${src_path}/.build_arch"

    if [[ -f "${arch_marker}" ]]; then
        local prev_arch
        prev_arch="$(<"${arch_marker}")"
        if [[ "${prev_arch}" == "${arch}" ]]; then
            log "Already compiled for ${arch}, skipping"
            return
        fi
    fi

    # Clean stale artifacts from previous (possibly failed) builds
    if [[ -f "${src_path}/Makefile" ]]; then
        log "Cleaning stale build artifacts..."

        # If make distclean fails, the script continues
        make -C "${src_path}" distclean >> "${logs_dir}/${library}-${arch}-compile.log" 2>&1 || true
    fi

    log "Compiling ${library} ${version} for ${arch}..."
    setup_toolchain "${arch}"
    "compile_${library}" "$(config_target_of "${arch}")"
    echo "${arch}" > "${arch_marker}"
}

step_extract_objects() {
    local src_path="${src_dir}/${src_subdir}"

    log "Extracting .o files from static archives..."

    local archive_count=0
    local obj_count=0
    while IFS= read -r -d '' archive; do
        local archive_base="$(basename "${archive}")"
        archive_base="${archive_base%.*}"

        # Create per-archive subdirectory: <version>/<arch>/<archive_name>/
        # This is required by CreateMultipleLibraries.java which expects
        # subfolders at depth 4 from the root folder to find programs.
        local lib_dir="${binary_dir}/${version}/${arch}/${archive_base}"
        mkdir -p "${lib_dir}"

        log "  Extracting ${archive_base}... -> ${lib_dir}/"
        ar x "${archive}" --output "${lib_dir}/" 2>/dev/null || true

        # Clean non-object artifacts from this archive's output
        find "${lib_dir}" -type f ! \( -name '*.o' -o -name '*.obj' \) -delete 2>/dev/null || true

        local this_count=$(find "${lib_dir}" -name '*.o' | wc -l)
        obj_count=$((obj_count + this_count))
        archive_count=$((archive_count + 1))
    done < <(find "${src_path}" -name '*.a' -print0)

    log "Extracted ${obj_count} .o files from ${archive_count} archives"
    log "Output: ${binary_dir}/"

    if [[ "${obj_count}" -eq 0 ]]; then
        die "No .o files extracted — check build produced .a archives"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    log "=== Build for ${library} ${version} (${arch}) ==="
    log "Output directory: ${base_dir}/"

    setup_library

    log "--- Download ---"
    step_download

    log "--- Compile ---"
    step_compile

    log "--- Extract objects ---"
    step_extract_objects

    log "=== Done! ==="
    log "Logs:    ${logs_dir}/"
    log "Sources: ${src_dir}/"
    log "Output:  ${binary_dir}/ ($(find "${binary_dir}" -type f | wc -l) files)"
}

main
