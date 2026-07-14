#!/bin/bash

# analyze.sh - Creates a FIDB for a compiled library
# Usage:
#   ./analyze.sh [--binary] <ghidra_home> <library> <version> <bin_dir> [arch] [base_dir]
#
# The <bin_dir> is the directory produced by compile.sh (e.g.: output/bin/).
# It must contain: <library>/<variant>/<name>/<binary>
#
# With --binary, use the compiled binary (with symbols) instead of .o files.
# The binary path is derived automatically from the library name and version.
#
# Examples:
#   ./analyze.sh ~/ghidra_home openssl 4.0.0 output/bin
#   ./analyze.sh --binary ~/ghidra_home openssl 4.0.0 output/bin aarch64 output

# Bash strict mode is used
set -euo pipefail

# Detection of --binary flag
binary_mode=false
positional_args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--binary) binary_mode=true; shift ;;
		*) positional_args+=("$1"); shift ;;
	esac
done

# Reassigns the arguments with the binary flag removed
set -- "${positional_args[@]}"

exit_with_message() {
	echo "${1}" >&2
	exit 1
}

# Detection of correct number of arguments
if [[ $# -lt 3 || $# -gt 6 ]]; then
	exit_with_message "Usage: analyze.sh [--binary] <ghidra_home> <library> <version> <bin_dir> [arch] [base_dir]"
fi

ghidra_home="${1}"
library=	"${2}"
version=	"${3}"
bin_dir=	"${4:-output/bin}"
arch=		"${5:-x86_64}"
base_dir=	"${6:-output}"

variant="linux"
name="${library}"

# Validate arguments
if [[ ! -d "${ghidra_home}" ]]; then
	exit_with_message "Ghidra home directory \"${ghidra_home}\" doesn't exist"
fi

ghidra_headless="${ghidra_home}/support/analyzeHeadless"
ghidra_scripts="${ghidra_home}/Ghidra/Features/FunctionID/ghidra_scripts"

# Check ghidra headless utility
if [[ ! -x "${ghidra_headless}" ]]; then
	exit_with_message "Can't find 'analyzeHeadless' or it's not executable: ${ghidra_headless}"
fi

# Check ghidra_scripts directory
if [[ ! -d "${ghidra_scripts}" ]]; then
	exit_with_message "FunctionID scripts directory doesn't exist: ${ghidra_scripts}"
fi

script_dir="$(cd "$(dirname "${0}")" && pwd)"

# Library config
# Maps each library to where its compiled binary lives inside the source tree.
# Used only in binary mode (--binary).

setup_library() {
	src_subdir="${library}-${version}-${arch}"
	case "${library}" in
		openssl) binary_relpath="apps/openssl" ;;
		*) exit_with_message "Library '${library}' not supported in binary mode" ;;
	esac
}

# Directory layout
# The build directory from compile.sh has this structure:
#
#   output/
#   ├── bin/<library>/<variant>/<name>/<binary>   - Compiled libraries
#   ├── projects/      							  - Ghidra project files
#   ├── logs/          							  - all logs
#   └── fid_files/     							  - final .fidb output

projects_dir="${base_dir}/projects"
logs_dir="${base_dir}/logs"
output_dir="${base_dir}/fid_files"

mkdir -p "${projects_dir}" "${logs_dir}" "${output_dir}"

# Source selection
# Two modes:
#   objects (default): import .o files from bin/<library>/<variant>/<name>/
#   binary  (--binary): import a single compiled binary staged at the same depth

if $binary_mode; then
	# Binary mode: derive binary path from library metadata
	setup_library
	binary_path="${base_dir}/sources/${src_subdir}/${binary_relpath}"
	if [[ ! -f "${binary_path}" ]]; then
		exit_with_message "Binary not found at expected path: ${binary_path}"
	fi

	# Stage the binary in a temp tree matching the expected depth
	#   staging/<library>/<variant>/<name>/<version>/<arch>/binary/<binary>
	#   CreateMultipleLibraries root = /<project>/<variant>/<name>
	#   "binary/" is at depth 0 → populateLibrary finds the program
	staging_dir="${base_dir}/staging_${library}_${arch}"
	rm -rf "${staging_dir}"
	mkdir -p "${staging_dir}/${library}/${variant}/${name}/${version}/${arch}/binary"
	cp "${binary_path}" "${staging_dir}/${library}/${variant}/${name}/${version}/${arch}/binary/"
	printf "\tBinary mode: staged %s\n" "${binary_path}"
	import_root="${staging_dir}/${library}"
	binary_root="${staging_dir}/${library}/${variant}/${name}"
else
	# Objects mode: use the existing .o files from the compile output
	if [[ ! -d "${bin_dir}" ]]; then
		exit_with_message "Bin directory \"${bin_dir}\" doesn't exist"
	fi
	binary_root="${bin_dir}/${library}/${variant}/${name}"
	if [[ ! -d "${binary_root}" ]]; then
		exit_with_message "Expected directory not found: ${binary_root}/"
	fi
	file_count=$(find "${binary_root}" -type f | wc -l)
	if [[ "${file_count}" -eq 0 ]]; then
		exit_with_message "No files found in ${binary_root}/"
	fi
	printf "\tFound %d files in %s\n" "${file_count}" "${binary_root}"
	import_root="${bin_dir}/${library}"
fi

# Import and analyze
project="${library}"
project_dir="${projects_dir}/${project}"

echo "Processing lib: ${project}"

# Start fresh: remove any stale project from a previous run
rm -rf "${project_dir}"
mkdir -p "${project_dir}"

rm -f "${logs_dir}/${project}"*.log

printf "\tImporting and analyzing files\n"
"${ghidra_headless}" "${project_dir}" "${project}" \
	-import "${import_root}" \
	-recursive \
	-overwrite \
	-scriptPath "${ghidra_scripts};${script_dir}/ghidra_scripts" \
	-scriptlog "${logs_dir}/${project}-scripts.log" \
	-log "${logs_dir}/${project}-analyze.log" \
	-max-cpu "$(nproc)"

# Check for critical errors during import and analysis
if grep -q "Analysis succeeded for file" "${logs_dir}/${project}-analyze.log"; then
	printf "\tAnalysis succeeded\n"
else
	exit_with_message "FAILED! Analysis did not succeed. Check logs: ${logs_dir}/${project}-analyze.log"
fi

# Find all unique langids in the analyzer output
langids=$(sed -nr 's/^.*Using Language\/Compiler: (.+)$/\1/p' "${logs_dir}/${project}-analyze.log" | sed 's/:[^:]*$//' | sort -u)

# Loop through all language IDs detected in the binary
while read -r langid; do
	printf "\tGenerating FidDB file for langid: %s\n" "${langid}"

	# Create a unique filename per language/compiler, e.g. openssl_x86-LE-64-default.fidb
	langid_safe="$(echo "${langid}" | tr ':.' '-')"
	fidb_name="${project}_${langid_safe}.fidb"

	# Generate the fidb generation template file directly
	cat > "${project_dir}/CreateMultipleLibraries.properties" <<PROP_EOF
Duplicate Results File OK = ${logs_dir}/${project}-duplicates.txt
Do Duplication Detection Do you want to detect duplicates = true
Choose destination FidDB Please choose the destination FidDB for population = ${fidb_name}
Select root folder containing all libraries (at a depth of 3): = /${project}/${variant}/${name}
Common symbols file (optional): OK = ${project_dir}/common_symbols.txt
Enter LanguageID To Process Language ID: = ${langid}
PROP_EOF

	# These files must exist before running CreateMultipleLibraries
	cat /dev/null > "${logs_dir}/${project}-duplicates.txt"
	cat /dev/null > "${project_dir}/common_symbols.txt"

	# Remove any existing FIDB for this langid
	rm -f "${output_dir}/${fidb_name}"

	# Create an empty fidb and populate it
	"${ghidra_headless}" "${project_dir}" "${project}" \
	-noanalysis \
	-propertiesPath "${project_dir}" \
	-scriptPath "${ghidra_scripts};${script_dir}/ghidra_scripts" \
	-preScript CreateEmptyFidDatabase.java "${output_dir}/${fidb_name}" \
	-preScript CreateMultipleLibraries.java \
	-log "${logs_dir}/${project}-generation.log"

	if ! grep -q ERROR "${logs_dir}/${project}-generation.log"; then
		echo -e "\tOptimizing FidDB file"

		# Pack the database
		"${ghidra_headless}" "${project_dir}" "${project}" \
		-noanalysis \
		-scriptPath "${script_dir}/ghidra_scripts" \
		-preScript RepackFidHeadless.java "${output_dir}/${fidb_name}" \
		-log "${logs_dir}/${project}-repack.log"

		if grep -q ERROR "${logs_dir}/${project}-repack.log"; then
			rm -f "${output_dir}/${fidb_name}"
			exit_with_message "FAILED! Please check logs: ${logs_dir}/${project}-repack.log"
		fi
	else
		rm -f "${output_dir}/${fidb_name}"
		exit_with_message "FAILED! Please check logs: ${logs_dir}/${project}-generation.log"
	fi

done <<< "${langids}"

# Clean up staging directory in binary mode
if $binary_mode && [[ -d "${staging_dir}" ]]; then
	rm -rf "${staging_dir}"
fi

echo "DONE!"