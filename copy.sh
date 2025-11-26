#!/usr/bin/env bash
set -euo pipefail

# Benchmark copy performance from SOURCE to DESTINATION for different dataset sizes.
# For each size, the copy is repeated N_RUNS times and the average time is reported.
#
# Usage:
#   ./copy.sh /path/to/SOURCE /path/to/DESTINATION
#
# Requirements:
#   - bash
#   - dd
#   - cp
#   - bc (for floating point arithmetic) [not mandatory]
#   - python3 (for high-resolution timestamps)
#
# Output format (to stdout and CSV file):
#   size_MB; avg_time_seconds

########################
# Configuration section
########################

# Number of repetitions per size (fixed to 5 as requested)
N_RUNS=5

# Dataset sizes in MB
SIZES_MB=(100 200 500 1024 2048 3072 4096 5120)

########################
# Helper functions
########################

usage() {
    echo "Usage: $0 SOURCE_DIR DEST_DIR"
    echo
    echo "SOURCE_DIR: directory where temporary dataset files will be created."
    echo "DEST_DIR:   directory where dataset files will be copied during the benchmark."
    exit 1
}

check_dependencies() {
    local deps=("dd" "cp" "bc" "python3")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: required command '$cmd' not found in PATH." >&2
            exit 1
        fi
    done
}

# Return current time in seconds with microsecond precision as a decimal number.
now_seconds() {
    python3 - << 'EOF'
import time
print(f"{time.time():.6f}")
EOF
}

################################
# Argument parsing and checks
################################

if [[ $# -ne 2 ]]; then
    usage
fi

SOURCE_DIR=$1
DEST_DIR=$2

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: SOURCE_DIR '$SOURCE_DIR' does not exist or is not a directory." >&2
    exit 1
fi

if [[ ! -d "$DEST_DIR" ]]; then
    echo "Error: DEST_DIR '$DEST_DIR' does not exist or is not a directory." >&2
    exit 1
fi

check_dependencies

################################
# Prepare output CSV file
################################

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_FILE="copy_benchmark_results_${TIMESTAMP}.csv"

echo "size_MB; avg_time_seconds" | tee "$RESULTS_FILE"

################################
# Main benchmark loop
################################

for size in "${SIZES_MB[@]}"; do
    dataset_name="dataset_${size}MB.bin"
    src_file="${SOURCE_DIR}/${dataset_name}"
    total_time="0"

    echo "----------------------------------------"
    echo "Generating dataset of ${size} MB in ${SOURCE_DIR}..."
    # Create the dataset file using dd (size in MB)
    # conv=fsync ensures data is physically written before dd exits
    dd if=/dev/zero of="$src_file" bs=1M count="$size" conv=fsync status=none

    echo "Running ${N_RUNS} copy iterations for size ${size} MB..."

    for (( run=1; run<=N_RUNS; run++ )); do
        dest_file="${DEST_DIR}/${dataset_name}.run${run}"

        # High-resolution timing using Python + bc
        start_s=$(now_seconds)
        cp "$src_file" "$dest_file"
        end_s=$(now_seconds)

        # Compute elapsed time as a floating-point value (seconds)
        elapsed_sec=$(echo "scale=6; $end_s - $start_s" | bc)

        echo "  Run ${run}: ${elapsed_sec} s"

        # Accumulate total time as floating-point
        total_time=$(echo "scale=6; $total_time + $elapsed_sec" | bc)
    done

    # Compute average time (you can keep 3 decimals, or more if you want)
    avg_time=$(echo "scale=3; $total_time / $N_RUNS" | bc)

    # Print results in requested format
    echo "${size}; ${avg_time}" | tee -a "$RESULTS_FILE"

    # Clean up destination copies for this size
    rm -f "${DEST_DIR}/${dataset_name}.run"*
    # Clean up source dataset
    rm -f "$src_file"
done

echo "----------------------------------------"
echo "Benchmark finished."
echo "Results saved to: ${RESULTS_FILE}"
