#!/bin/bash

# compile.sh - Download and compile a library
# Usage: ./compile.sh <library> <version> [output_base_dir]
#
# Supported libraries: openssl
# Example: ./compile.sh openssl 4.0.0

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
            arch="x86_64"
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
    local src_path="${src_dir}/${src_subdir}"
    local archive_count=$(find "${src_path}" -maxdepth 1 -name '*.a' | wc -l)

    if [[ "${archive_count}" -gt 0 ]]; then
        log "Static libraries already built, skipping compilation"
        return
    fi

    log "Compiling ${library} ${version}..."
    "compile_${library}"
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
    log "=== Build for ${library} ${version} ==="
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
