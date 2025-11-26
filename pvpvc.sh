#!/usr/bin/env bash
set -euo pipefail

# Benchmark Kubernetes PVC creation and binding performance, as a proxy for
# PrepareData-like workspace preparation using PV/PVCs.
#
# For each "num_pvcs" value, the script:
#   - Repeats the experiment N_RUNS times.
#   - In each run:
#       * Creates that many PVCs in the target namespace using the given
#         StorageClass and size.
#       * Waits until ALL PVCs reach the 'Bound' phase (or timeout).
#       * Measures:
#           - Total wall-clock time for the run.
#           - User CPU time and System CPU time (/usr/bin/time).
#   - Computes the averages across runs.
#
# Output CSV format:
#   num_pvcs; avg_total_time_seconds; avg_user_cpu_seconds; avg_sys_cpu_seconds; avg_sys_cpu_fraction
#
#   where:
#     avg_sys_cpu_fraction = avg_sys_cpu_seconds / avg_total_time_seconds
#
# Usage:
#   ./pvc_preparedata_benchmark.sh NAMESPACE STORAGE_CLASS PVC_SIZE
#
#   Example:
#     ./pvc_preparedata_benchmark.sh pd-bench sc-cephfs 1Gi
#
# Notes:
#   - Requires 'kubectl' configured with access to the target cluster/namespace.
#   - Requires a valid StorageClass name.
#   - PVC_SIZE must be a valid Kubernetes quantity (e.g. 1Gi, 512Mi, 10Gi, ...).
#
# Requirements:
#   - bash
#   - kubectl
#   - bc
#   - python3
#   - /usr/bin/time (GNU time, for formatted user/system CPU output)

########################
# Configuration section
########################

# Number of repetitions per "num_pvcs" scenario
N_RUNS=5

# Different numbers of PVCs to test per run (tune as needed)
NUM_PVCS_LIST=(5 10 20 50 100)

# Timeout waiting for each PVC to become Bound (e.g. "300s")
PVC_TIMEOUT="300s"

########################
# Helper functions
########################

usage() {
    echo "Usage: $0 NAMESPACE STORAGE_CLASS PVC_SIZE"
    echo
    echo "NAMESPACE:      Kubernetes namespace where PVCs will be created."
    echo "STORAGE_CLASS:  StorageClass name to use for the PVCs."
    echo "PVC_SIZE:       Size of each PVC (e.g. 1Gi, 512Mi)."
    exit 1
}

check_dependencies() {
    local deps=("kubectl" "bc" "python3")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: required command '$cmd' not found in PATH." >&2
            exit 1
        fi
    done

    # Check specifically for /usr/bin/time (GNU time)
    if ! command -v /usr/bin/time >/dev/null 2>&1; then
        echo "Error: /usr/bin/time not found. Please install GNU time (often package 'time')." >&2
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

if [[ $# -ne 3 ]]; then
    usage
fi

NAMESPACE=$1
STORAGE_CLASS=$2
PVC_SIZE=$3

check_dependencies

# Basic sanity check: namespace exists
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: namespace '$NAMESPACE' does not exist or is not accessible." >&2
    exit 1
fi

################################
# Prepare output CSV file
################################

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_FILE="pvc_preparedata_benchmark_results_${TIMESTAMP}.csv"

echo "num_pvcs; avg_total_time_seconds; avg_user_cpu_seconds; avg_sys_cpu_seconds; avg_sys_cpu_fraction" | tee "$RESULTS_FILE"

################################
# Main benchmark loop
################################

for num_pvcs in "${NUM_PVCS_LIST[@]}"; do
    echo "----------------------------------------"
    echo "Testing scenario with ${num_pvcs} PVCs..."

    total_wall_time="0"
    total_user_time="0"
    total_sys_time="0"

    for (( run=1; run<=N_RUNS; run++ )); do
        echo "  Run ${run}/${N_RUNS} for ${num_pvcs} PVCs..."

        # Prefix to generate unique PVC names for this run
        pvc_name_prefix="pvcbench-${num_pvcs}-${run}-"

        # Temporary file to store /usr/bin/time output (user;system)
        tmp_time_file=$(mktemp)

        # Measure wall-clock time around the PVC storm
        start_s=$(now_seconds)

        # Run the PVC storm in a child shell, measured by /usr/bin/time
        /usr/bin/time -f "%U;%S" -o "$tmp_time_file" \
            bash -c '
                num_pvcs="$1"
                ns="$2"
                sc="$3"
                size="$4"
                prefix="$5"
                timeout="$6"

                # 1) Create PVCs
                for i in $(seq 1 "$num_pvcs"); do
                    name="${prefix}${i}"
                    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${size}
  storageClassName: ${sc}
EOF
                done

                # 2) Wait for all PVCs to be Bound
                for i in $(seq 1 "$num_pvcs"); do
                    name="${prefix}${i}"
                    echo "      waiting for pvc/${name} to be Bound..."
                    kubectl -n "$ns" wait --for=condition=Bound --timeout="$timeout" "pvc/${name}"
                done
            ' bash "$num_pvcs" "$NAMESPACE" "$STORAGE_CLASS" "$PVC_SIZE" "$pvc_name_prefix" "$PVC_TIMEOUT"

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

        # 3) Cleanup: delete PVCs from this run
        echo "    Cleaning up PVCs for this run..."
        for i in $(seq 1 "$num_pvcs"); do
            name="${pvc_name_prefix}${i}"
            kubectl -n "$NAMESPACE" delete pvc "$name" --ignore-not-found=true >/dev/null 2>&1 || true
        done
    done

    # Average times for this scenario (across runs)
    avg_wall_time=$(echo "scale=3; $total_wall_time / $N_RUNS" | bc)
    avg_user_time=$(echo "scale=3; $total_user_time / $N_RUNS" | bc)
    avg_sys_time=$(echo "scale=3; $total_sys_time / $N_RUNS" | bc)

    # Avoid division by zero (should not happen in practice, but just in case)
    if [ "$(echo "$avg_wall_time == 0" | bc -l)" -eq 1 ]; then
        avg_sys_fraction="0"
    else
        avg_sys_fraction=$(echo "scale=3; $avg_sys_time / $avg_wall_time" | bc)
    fi

    # Output in requested format
    echo "${num_pvcs}; ${avg_wall_time}; ${avg_user_time}; ${avg_sys_time}; ${avg_sys_fraction}" | tee -a "$RESULTS_FILE"
done

echo "----------------------------------------"
echo "PVC PrepareData-like benchmark finished."
echo "Results saved to: ${RESULTS_FILE}"
