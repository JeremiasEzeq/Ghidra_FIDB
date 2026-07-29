#!/bin/bash

# compile.sh - Download and compile a library
# Usage:
#        ./compile.sh <library> <version> [arch] [output_base_dir]
#
# Supported libraries: openssl
# Supported architectures: x86_64, aarch64, arm, mips64el
# Examples:
#        ./compile.sh openssl 4.0.0               (default: x86_64)
#        ./compile.sh openssl 4.0.0 aarch64
#        ./compile.sh openssl 4.0.0 arm
# Bash strict mode is used
set -euo pipefail

# Helper functions
log()   { echo "[$(date '+%H:%M:%S')] $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }
check() { command -v "$1" &>/dev/null || die "Required tool not found: $1"; }

# Detect correct number of arguments
if [[ $# -lt 2 || $# -gt 4 ]]; then
    die "Usage: compile.sh <library> <version> [arch] [output_base_dir]"
fi

library="${1}"
version="${2}"
arch="${3:-x86_64}"
base_dir="${4:-output}"

# Check necessary dependencies
check curl
check tar
check make

# Exporting CC, AR and RANLIB, neccesary for cross-compilation in the specified architecture
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

# Mapping of input argument architecture
config_target_of() {
    case "${1}" in
        x86_64)   echo "linux-x86_64"   ;;
        aarch64)  echo "linux-aarch64"  ;;
        arm)      echo "linux-armv4"    ;;
        mips64el) echo "linux-mips64"   ;;
    esac
}

#  Directory layout 
#
# output/
# ├── sources/   - downloaded tarballs
# │   └── <library>-<version>-<arch>  <- the binary goes here
# ├── bin/       - compiled binaries, structured for Ghidra import
# │   └── <library>/linux/<library>/<version>/<arch>  <- the binary goes here
# ├── projects/  - Ghidra project files
# ├── logs/      - all logs
# └── fid_files/ - final .fidb output

src_dir="${base_dir}/sources"
bin_dir="${base_dir}/bin"
projects_dir="${base_dir}/projects"
logs_dir="${base_dir}/logs"

mkdir -p "${src_dir}" "${bin_dir}" "${projects_dir}" "${logs_dir}"

# Library-specific config 
setup_library_config() {
    case "${library}" in
        openssl)
            tarball_url="https://github.com/openssl/openssl/releases/download/openssl-${version}/openssl-${version}.tar.gz"
            tarball_name="openssl-${version}.tar.gz"
            src_subdir="openssl-${version}-${arch}"
            variant="linux"
            name="openssl"
            ;;
        libcurl | curl)
            tarball_url="https://curl.se/download/curl-${version}.tar.gz"
            tarball_name="curl-${version}.tar.gz"
            src_subdir="curl-${version}-${arch}"
            variant="linux"
            name="curl"
            library="curl"
            ;;
        jsoncpp)
            tarball_url="https://github.com/open-source-parsers/jsoncpp/archive/refs/tags/${version}.tar.gz"
            tarball_name="${version}.tar.gz"
            src_subdir="jsoncpp-${version}-${arch}"
            variant="linux"
            name="jsoncpp"
            ;;

        *)
            die "Unsupported library: '${library}'. Supported: openssl, libcurl, jsoncpp"
            ;;
    esac

    # Where the binary will live for Ghidra import
    binary_dir="${bin_dir}/${library}/${variant}/${name}"
    mkdir -p "${binary_dir}"
}

# ==============================================================
# Library dependent compile functions 
# ==============================================================

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

compile_curl() {
    local config_target="$1"
    local compile_log="$(pwd)/${logs_dir}/${library}-${arch}-compile.log"
    local src_path="${src_dir}/${src_subdir}"

    # Libcurl needs an OpenSSL installation
    local openssl_path="$(pwd)/$(ls -dt "${src_dir}/openssl-"*-"${arch}" 2>/dev/null | head -1)"
    if [[ -z "${openssl_path}" ]]; then
        die "No OpenSSL build found for ${arch}. Run ./compile.sh openssl <ver> ${arch} first"
    fi

    log "Configuring Libcurl ${version} for ${arch} (target: ${config_target})..."
    pushd "${src_path}" > /dev/null
        # ./configure --disable-symbol-hiding --disable-shared --without-libpsl --without-brotli --without-zstd --with-openssl CPPFLAGS="-I/home/jeremias/TFG/Ghidra_FIDB/output/sources/openssl-4.0.0-x86_64/include" LDFLAGS="-L/home/jeremias/TFG/Ghidra_FIDB/output/sources/openssl-4.0.0-x86_64" LIBS="-lssl -lcrypto"
        ./configure --disable-symbol-hiding --disable-shared --without-libpsl --without-brotli --without-zstd --with-openssl=${openssl_path} CPPFLAGS="-I${openssl_path}/include" LDFLAGS="-L${openssl_path}" >> "${compile_log}" 2>&1

        log "Compiling Libcurl ${version} for ${arch}..."
        make LIBS="-lssl -lcrypto" -j"$(nproc)" >> "${compile_log}" 2>&1
    popd > /dev/null
}

compile_jsoncpp() {
    local config_target="$1"
    local compile_log="$(pwd)/${logs_dir}/${library}-${arch}-compile.log"

    log "Configuring Jsoncpp ${version} for ${arch} (target: ${config_target})..."
    pushd "${src_path}" > /dev/null
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DJSONCPP_WITH_TESTS=OFF \
        -DJSONCPP_WITH_POST_BUILD_UNITTEST=OFF \
        -DCMAKE_C_COMPILER="${CC:-gcc}" \
        -DCMAKE_CXX_COMPILER="${CXX:-g++}" \
        "${src_path}" \
        >> "${compile_log}" 2>&1

    cmake --build build -j"$(nproc)" >> "${compile_log}" 2>&1
    popd > /dev/null

}

# ==============================================================
# Pipeline steps 
# ==============================================================

# Downloads and extracts the tarball of the specified library, if not present
download_library() {
    local tarball="${src_dir}/${tarball_name}"

    if [[ -f "${tarball}" ]]; then
        log "Tarball already downloaded, skipping: ${tarball_name}"
    else
        log "Downloading ${library} ${version} from ${tarball_url}..."
        curl -L --fail --progress-bar -o "${tarball}" "${tarball_url}" \
            || die "Download failed"
    fi

	if [[ ! -d "${src_dir}/${src_subdir}" ]]; then
        local extracted="${src_dir}/${library}-${version}"

        # Remove stale plain-name dir (from old runs before arch suffix)
        if [[ -d "${extracted}" ]]; then
            rm -rf "${extracted}"
        fi

        log "Extracting ${tarball_name}..."
        tar -xzf "${tarball}" -C "${src_dir}" \
            || die "Extraction failed"
        
        # Rename to arch-specific name so each arch keeps its own source tree
        mv "${extracted}" "${src_dir}/${src_subdir}" \
            || die "Failed to rename extracted directory"
    else
        log "Source already extracted, skipping."
    fi
}

# Sets up the compilation for the specified library and executes the library dependent compilation function
compile_library() {
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

# Extracts .o files from .a files in the library
extract_objects() {
    local src_path="${src_dir}/${src_subdir}"

    log "Extracting .o files from static archives..."

    local archive_count=0
    local obj_count=0
    while IFS= read -r -d '' archive; do
        # The name of the .a file is extracted into archive_base
        local archive_base="$(basename "${archive}")"

        # The .a extension is removed
        archive_base="${archive_base%.*}"

        # Create per-archive subdirectory: <version>/<arch>/<archive_name>/
        # This is required by CreateMultipleLibraries.java which expects
        # subfolders at depth 4 from the root folder to find programs.
        local lib_dir="${binary_dir}/${version}/${arch}/${archive_base}"
        mkdir -p "${lib_dir}"
        log "  Extracting ${archive_base}... -> ${lib_dir}/"

        # The contents of the .a file are extracted into its lib_dir directory
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
        die "No .o files extracted. Check build produced .a archives"
    fi
}


main() {
    log "=== Build for ${library} ${version} (${arch}) ==="
    log "Output directory: ${base_dir}/"

    setup_library_config

    log "--- Download ---"
    download_library

    log "--- Compile ---"
    compile_library

    log "--- Extract objects ---"
    extract_objects

    log "=== Done! ==="
    log "Logs:    ${logs_dir}/"
    log "Sources: ${src_dir}/"
    log "Output:  ${binary_dir}/ ($(find "${binary_dir}" -type f | wc -l) files)"
}

main
