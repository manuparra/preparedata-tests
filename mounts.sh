#!/usr/bin/env bash
set -euo pipefail

# Benchmark bind mount performance on a single node.
# For each "number of mounts" value, the script:
#   - Repeats the experiment N_RUNS times.
#   - In each run, creates that many bind mounts sequentially.
#   - Measures:
#       * Total wall-clock time for the run.
#       * User CPU time and System CPU time (via /usr/bin/time).
#   - Computes the average across runs.
#
# Output format:
#   num_mounts; avg_total_time_seconds; avg_user_cpu_seconds; avg_sys_cpu_seconds; avg_sys_cpu_fraction
#
#   where:
#     avg_sys_cpu_fraction = avg_sys_cpu_seconds / avg_total_time_seconds
#
# Usage:
#   sudo ./mounts.sh SOURCE_DIR DEST_BASE_DIR
#
# Notes:
#   - Must be run as root (mount/umount).
#   - SOURCE_DIR is the directory to be bind-mounted many times.
#   - DEST_BASE_DIR will contain per-run subdirectories where mount points are created.
#
# Requirements:
#   - bash
#   - mount / umount
#   - bc
#   - python3
#   - /usr/bin/time (GNU time, for formatted user/system CPU output)

########################
# Configuration section
########################

# Number of repetitions per "num_mounts" scenario
N_RUNS=5

# Different numbers of bind mounts to test
NUM_MOUNTS_LIST=(10 50 100 200 400 800)

########################
# Helper functions
########################

usage() {
    echo "Usage: sudo $0 SOURCE_DIR DEST_BASE_DIR"
    echo
    echo "SOURCE_DIR:     directory that will be used as the bind-mount source."
    echo "DEST_BASE_DIR:  base directory where mount points will be created."
    exit 1
}

check_dependencies() {
    local deps=("mount" "umount" "bc" "python3")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: required command '$cmd' not found in PATH." >&2
            exit 1
        fi
    done

    # Check specifically for /usr/bin/time (GNU time)
    if ! command -v /usr/bin/time >/dev/null 2>&1; then
        echo "Error: /usr/bin/time not found. Please install GNU time." >&2
        exit 1
    fi
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
DEST_BASE_DIR=$2

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo) to use mount/umount." >&2
    exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: SOURCE_DIR '$SOURCE_DIR' does not exist or is not a directory." >&2
    exit 1
fi

mkdir -p "$DEST_BASE_DIR"

check_dependencies

################################
# Prepare output CSV file
################################

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_FILE="bind_mount_benchmark_results_${TIMESTAMP}.csv"

echo "num_mounts; avg_total_time_seconds; avg_user_cpu_seconds; avg_sys_cpu_seconds; avg_sys_cpu_fraction" | tee "$RESULTS_FILE"

################################
# Main benchmark loop
################################

for num_mounts in "${NUM_MOUNTS_LIST[@]}"; do
    echo "----------------------------------------"
    echo "Testing scenario with ${num_mounts} bind mounts..."

    total_wall_time="0"
    total_user_time="0"
    total_sys_time="0"

    for (( run=1; run<=N_RUNS; run++ )); do
        echo "  Run ${run}/${N_RUNS} for ${num_mounts} mounts..."

        # Per-run directory to host all mount points
        run_dir="${DEST_BASE_DIR}/run_${num_mounts}_${run}"
        mkdir -p "$run_dir"

        # Temporary file to store /usr/bin/time output (user;system)
        tmp_time_file=$(mktemp)

        # Measure wall-clock time around the mount storm
        start_s=$(now_seconds)

        # Run the mount storm in a child shell, measured by /usr/bin/time
        /usr/bin/time -f "%U;%S" -o "$tmp_time_file" \
            bash -c '
                num_mounts="$1"
                src="$2"
                run_dir="$3"

                for i in $(seq 1 "$num_mounts"); do
                    dest="${run_dir}/mount_${i}"
                    mkdir -p "$dest"
                    mount --bind "$src" "$dest"
                done
            ' bash "$num_mounts" "$SOURCE_DIR" "$run_dir"

        end_s=$(now_seconds)

        # Wall-clock elapsed time
        elapsed_sec=$(echo "scale=6; $end_s - $start_s" | bc)
        echo "    Elapsed (wall): ${elapsed_sec} s"

        # Read user and system CPU times from /usr/bin/time output
        IFS=';' read -r user_time_run sys_time_run < "$tmp_time_file"
        rm -f "$tmp_time_file"

        echo "    CPU user: ${user_time_run} s, CPU sys: ${sys_time_run} s"

        # Accumulate totals across runs
        total_wall_time=$(echo "scale=6; $total_wall_time + $elapsed_sec" | bc)
        total_user_time=$(echo "scale=6; $total_user_time + $user_time_run" | bc)
        total_sys_time=$(echo "scale=6; $total_sys_time + $sys_time_run" | bc)

        # Cleanup: unmount and remove mount points
        for i in $(seq 1 "$num_mounts"); do
            dest="${run_dir}/mount_${i}"
            umount "$dest"
            rmdir "$dest"
        done
        rmdir "$run_dir"
    done

    # Average times for this scenario (across runs)
    avg_wall_time=$(echo "scale=3; $total_wall_time / $N_RUNS" | bc)
    avg_user_time=$(echo "scale=3; $total_user_time / $N_RUNS" | bc)
    avg_sys_time=$(echo "scale=3; $total_sys_time / $N_RUNS" | bc)

    # Avoid division by zero just in case (should not happen in practice)
    if echo "$avg_wall_time == 0" | bc -l >/dev/null 2>&1 && \
       echo "$avg_wall_time == 0" | bc -l | grep -q "^1$"; then
        avg_sys_fraction="0"
    else
        avg_sys_fraction=$(echo "scale=3; $avg_sys_time / $avg_wall_time" | bc)
    fi

    # Output in requested format
    echo "${num_mounts}; ${avg_wall_time}; ${avg_user_time}; ${avg_sys_time}; ${avg_sys_fraction}" | tee -a "$RESULTS_FILE"
done

echo "----------------------------------------"
echo "Bind mount benchmark finished."
echo "Results saved to: ${RESULTS_FILE}"
