#!/bin/bash

# compile.sh - Download and compile a library
# Usage: ./compile.sh <library> <version> [output_base_dir]
#
# Supported libraries: openssl
# Example: ./compile.sh openssl 3.5.0

set -euo pipefail

# ─── Helpers ────────────────────────────────────────────────────────────────

log()   { echo "[$(date '+%H:%M:%S')] $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }
check() { command -v "$1" &>/dev/null || die "Required tool not found: $1"; }

# ─── Args ───────────────────────────────────────────────────────────────────

if [[ $# -lt 2 || $# -gt 3 ]]; then
    die "Usage: ${0} <library> <version> [output_base_dir]"
fi

library="${1}"
version="${2}"
base_dir="${3:-output}"

# ─── Check dependencies ─────────────────────────────────────────────────────

check curl
check tar
check make
check envsubst

# ─── Directory layout ───────────────────────────────────────────────────────
#
# output/
# ├── sources/   - downloaded tarballs
# ├── build/     - compiled binaries, structured for Ghidra import
# │   └── <library>/linux/<library>/<version>/  ← the binary goes here
# ├── projects/  - Ghidra project files
# ├── logs/      - all logs
# └── fid_files/ - final .fidb output

src_dir="${base_dir}/sources"
build_dir="${base_dir}/build"
projects_dir="${base_dir}/projects"
logs_dir="${base_dir}/logs"

mkdir -p "${src_dir}" "${build_dir}" "${projects_dir}" "${logs_dir}"

# ─── Library-specific config ────────────────────────────────────────────────

setup_library() {
    case "${library}" in
        openssl)
            tarball_url="https://github.com/openssl/openssl/releases/download/openssl-${version}/openssl-${version}.tar.gz"
            tarball_name="openssl-${version}.tar.gz"
            src_subdir="openssl-${version}"
            variant="linux"
            name="openssl"
            arch="x86_64"
            ;;
        *)
            die "Unsupported library: '${library}'. Supported: openssl"
            ;;
    esac

    # Where the binary will live for Ghidra import
    binary_dir="${build_dir}/${library}/${variant}/${name}"
    mkdir -p "${binary_dir}"
}

# ─── Compile functions ───────────────────────────────────────────────────────

compile_openssl() {
    local compile_log="$(pwd)/${logs_dir}/${library}-compile.log"
    local src_path="${src_dir}/${src_subdir}"

    log "Configuring OpenSSL ${version}..."
    pushd "${src_path}" > /dev/null
        ./Configure \
            -static \
            >> "${compile_log}" 2>&1

        log "Compiling OpenSSL ${version} (this may take a few minutes)..."
        make -j"$(nproc)" >> "${compile_log}" 2>&1
    popd > /dev/null

    # Copy the main binary into the Ghidra-expected directory structure
    local binary="${src_path}/apps/openssl"
    [[ -f "${binary}" ]] || die "Expected binary not found after build: ${binary}"
    cp "${binary}" "${binary_dir}/${library}"
    log "Binary copied to ${binary_dir}/${library}"
}

# ─── Pipeline steps ─────────────────────────────────────────────────────────

step_download() {
    local tarball="${src_dir}/${tarball_name}"

    if [[ -f "${tarball}" ]]; then
        log "Tarball already downloaded, skipping: ${tarball_name}"
    else
        log "Downloading ${library} ${version} from ${tarball_url}..."
        curl -L --fail --progress-bar \
            -o "${tarball}" \
            "${tarball_url}" \
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
    local binary="${binary_dir}/${library}"

    if [[ -f "${binary}" ]]; then
        log "Binary already exists, skipping compilation: ${binary}"
        return
    fi

    log "Compiling ${library} ${version}..."
    "compile_${library}"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    log "=== Build for ${library} ${version} ==="
    log "Output directory: ${base_dir}/"

    setup_library

    log "--- Download ---"
    step_download

    log "--- Compile ---"
    step_compile

    log "=== Done! ==="
    log "Logs:    ${logs_dir}/"
    log "Sources: ${src_dir}/"
    log "Binary:  ${binary_dir}/${library}"
}

main
