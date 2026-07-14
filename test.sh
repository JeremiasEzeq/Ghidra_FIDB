#!/bin/bash

# test.sh - Test a FIDB against a compiled library (binary or objects)
# Usage:
#   --binary:  ./test.sh --binary <ghidra_home> <binary_path> <fidb_file> [generation_log] [arch] [output_dir]
#   objects:   ./test.sh <ghidra_home> <objects_dir> <fidb_file> [generation_log] [arch] [output_dir]
#
# In --binary mode, strips a single compiled binary and tests the FIDB against it.
# In objects mode, strips all .o files under <objects_dir> and tests the FIDB
# against every imported program, aggregating the results.
#
# Examples:
#   ./test.sh --binary ~/ghidra_home output/sources/openssl-4.0.0-x86_64/apps/openssl output/fid_files/openssl_x86-LE-64-default.fidb
#   ./test.sh ~/ghidra_home output/bin/openssl/linux/openssl/4.0.0/x86_64 output/fid_files/openssl_x86-LE-64-default.fidb

# Bash strict mode is used
set -euo pipefail

exit_with_message() {
	echo "${1}" >&2
	exit 1
}

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

# Detection of correct number of arguments
if [[ $# -lt 3 || $# -gt 6 ]]; then
	exit_with_message "Usage: ${0} [--binary] <ghidra_home> <path> <fidb_file> [generation_log] [arch] [output_dir]"
fi

# Input arguments saved into variables
ghidra_home=	"${1}"
input_path=		"${2}"
fidb_file=		"${3}"
generation_log=	"${4:-}"
arch=			"${5:-x86_64}"
output_dir=		"${6:-test_output}"

# Project paths for the fidb analysis
script_dir="$(cd "$(dirname "${0}")" && pwd)"
project_dir="${output_dir}/project"
logs_dir="${output_dir}/logs"

# Output file
report_file="${logs_dir}/fid_report.txt"

# Check of necessary files: fidb and analyzeHeadless utility
if [[ ! -f "${fidb_file}" ]]; then
	exit_with_message "FIDB file not found: ${fidb_file}"
fi
if [[ ! -x "${ghidra_home}/support/analyzeHeadless" ]]; then
	exit_with_message "analyzeHeadless not found or not executable: ${ghidra_home}/support/analyzeHeadless"
fi

rm -rf "${project_dir}"
mkdir -p "${project_dir}" "${logs_dir}"

# Stripping tool selection
case "${arch}" in
	aarch64) strip_tool="aarch64-linux-gnu-strip" ;;
	arm)     strip_tool="arm-linux-gnueabihf-strip" ;;
	mips64el) strip_tool="mips64el-linux-gnuabi64-strip" ;;
	*)       strip_tool="strip" ;;
esac

# Use of selected strip tool, or native strip if absent
if ! command -v "${strip_tool}" &>/dev/null; then
    echo "WARNING: ${strip_tool} not found, trying native strip..."
    strip_tool="strip"
fi


# ==============================================================
# 1.- BINARY MODE, for analyzing one binary file
# ==============================================================
if $binary_mode; then
	if [[ ! -f "${input_path}" ]]; then
		exit_with_message "Binary not found: ${input_path}"
	fi

	binary_name="$(basename "${input_path}")"
	stripped_binary="${output_dir}/${binary_name}_stripped"

	# 1.1.- Strip the binary
	rm -f "${stripped_binary}"
	cp "${input_path}" "${stripped_binary}"
	"${strip_tool}" "${stripped_binary}"

	original_count=$(nm "${input_path}" 2>/dev/null | grep -c " [Tt] " || true)
	stripped_count=$(nm "${stripped_binary}" 2>/dev/null | grep -c " [Tt] " || true)

	printf "Original binary: %s\t text symbols\n" "${original_count}"
	printf "Stripped binary: %s\t text symbols\n" "${stripped_count}"


	# 1.2.- Import and register the input FIDB, and analyze the stripped binary with it
	rm -f "${report_file}"
	printf "\nImporting, registering FIDB, and analyzing...\n"

	"${ghidra_home}/support/analyzeHeadless" \
		"${project_dir}" "TestProject" \
		-import "${stripped_binary}" \
		-overwrite \
		-scriptPath "${script_dir}/ghidra_scripts" \
		-preScript RegisterFidb.java "${fidb_file}" \
		-postScript FidbTestReport.java "${report_file}" \
		-log "${logs_dir}/analysis.log" \
		-scriptlog "${logs_dir}/scripts.log" \
		-max-cpu "$(nproc)"

	if [[ ! -f "${report_file}" ]]; then
		exit_with_message "Report file not generated. Check logs: ${logs_dir}/"
	fi


	# 1.3.- Parse postScript output
	identified_count=$(sed -n 's/^Functions identified by name: \([0-9]*\)/\1/p' "${report_file}" | head -1)
	program_funcs=$(sed -n 's/^Functions in program: \([0-9]*\)/\1/p' "${report_file}" | head -1)

	printf "\n=== FIDB Test Report ===\n"
	echo "Binary:              ${binary_name}"
	echo "Functions identified: ${identified_count:-N/A}"
	echo "Program functions:    ${program_funcs:-N/A}"

	# 1.4.- Compute identification rate vs original
	if [[ -n "${identified_count}" && "${original_count}" -gt 0 ]]; then
		rate=$(echo "scale=1; ${identified_count} * 100 / ${original_count}" | bc 2>/dev/null || echo "?")
		echo "Identification rate:  ${rate}%"
	fi

	echo "Original symbols:     ${original_count}"
	echo "Stripped symbols:     ${stripped_count}"
	echo "FIDB file:            ${fidb_file}"
	echo "=== End Report ==="

# ==================================================================================================
# 2.- OBJECTS MODE, for analysis of a group of .o files
# ==================================================================================================
else
	if [[ ! -d "${input_path}" ]]; then
		exit_with_message "Objects directory not found: ${input_path}"
	fi

	# 2.1.- Count original text symbols across all .o files
	original_count=0
	while IFS= read -r -d '' f; do
		c=$(nm "$f" 2>/dev/null | grep -c " [Tt] " || true)
		original_count=$((original_count + c))
	done < <(find "${input_path}" -name '*.o' -print0)
	printf "Original objects: %s text symbols across %s files\n" "${original_count}" \
		"$(find "${input_path}" -name '*.o' | wc -l)"


	# 2.2.- Stage and strip all .o files
	staging_dir="${output_dir}/stripped_objects"
	rm -rf "${staging_dir}"
	mkdir -p "${staging_dir}"
	cp -r "${input_path}/." "${staging_dir}/"
	while IFS= read -r -d '' f; do
		"${strip_tool}" "$f" 2>/dev/null || true
	done < <(find "${staging_dir}" -name '*.o' -print0)


	# 2.3.- Count remaining symbols after strip
	stripped_count=0
	while IFS= read -r -d '' f; do
		c=$(nm "$f" 2>/dev/null | grep -c " [Tt] " || true)
		stripped_count=$((stripped_count + c))
	done < <(find "${staging_dir}" -name '*.o' -print0)
	printf "Stripped objects: %s text symbols\n" "${stripped_count}"


	# 2.4.- Import, register FIDB, and analyze
	rm -f "${report_file}"
	printf "\nImporting, registering FIDB, and analyzing...\n"

	"${ghidra_home}/support/analyzeHeadless" \
		"${project_dir}" "TestProject" \
		-import "${staging_dir}" \
		-recursive \
		-overwrite \
		-scriptPath "${script_dir}/ghidra_scripts" \
		-preScript RegisterFidb.java "${fidb_file}" \
		-postScript FidbTestReport.java "${report_file}" \
		-log "${logs_dir}/analysis.log" \
		-scriptlog "${logs_dir}/scripts.log" \
		-max-cpu "$(nproc)"

	if [[ ! -f "${report_file}" ]]; then
		exit_with_message "Report file not generated. Check logs: ${logs_dir}/"
	fi


	# 2.5.- Aggregate results across all programs
	total_identified=$(awk -F': ' '/^Functions identified by name:/ {s+=$2} END {print s+0}' "${report_file}")
	total_program=$(awk -F': ' '/^Functions in program:/ {s+=$2} END {print s+0}' "${report_file}")
	program_count=$(grep -c '^Program:' "${report_file}" || true)

	printf "\n=== FIDB Test Report ===\n"
	echo "Objects dir:        ${input_path}"
	echo "Programs imported:   ${program_count}"
	echo "Functions total:     ${total_program}"
	echo "Functions identified: ${total_identified}"


	# 2.6.- Compute identification rate vs original
	if [[ "${total_identified}" -gt 0 && "${original_count}" -gt 0 ]]; then
		rate=$(echo "scale=1; ${total_identified} * 100 / ${original_count}" | bc 2>/dev/null || echo "?")
		echo "Identification rate: ${rate}%"
	fi

	echo "Original symbols:    ${original_count}"
	echo "Stripped symbols:    ${stripped_count}"
	echo "FIDB file:           ${fidb_file}"
	echo "=== End Report ==="


	# 2.7.- Clean up staging directory
	rm -rf "${staging_dir}"
fi

# 3.- Print generation-log info, if available
if [[ -n "${generation_log}" && -f "${generation_log}" ]]; then
	fidb_count=$(sed -n 's/.*Added \([0-9]*\) library entries.*/\1/p' "${generation_log}" | head -1)

	if [[ -z "${fidb_count}" ]]; then
		fidb_count=$(sed -n 's/.*\([0-9]*\) library entries defined.*/\1/p' "${generation_log}" | head -1)
	fi

	echo "Functions in FIDB:   ${fidb_count:-N/A}"
fi
