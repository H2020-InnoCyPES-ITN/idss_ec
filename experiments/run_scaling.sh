#!/bin/bash

# Run repeatable IDSS scaling experiments and write CSV measurements.
#
# Usage: ./experiments/run_scaling.sh <max_peers> <repeats>

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <max_peers> <repeats>"
    exit 1
fi

MAX_PEERS=$1
REPEATS=$2
if ! [[ "${MAX_PEERS}" =~ ^[0-9]+$ ]] || ! [[ "${REPEATS}" =~ ^[0-9]+$ ]] || (( MAX_PEERS < 2 || REPEATS < 1 )); then
    echo "max_peers must be at least 2 and repeats must be at least 1" >&2
    exit 1
fi

for command in go python3 curl; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command not found: ${command}" >&2
        echo "Install Go 1.23+, Python 3, and curl, then rerun this script." >&2
        exit 1
    fi
done

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SERVER_DIR="${ROOT_DIR}/server"
CLIENT_DIR="${ROOT_DIR}/client"
RESULT_DIR="${ROOT_DIR}/experiments/results"
CSV_FILE="${RESULT_DIR}/scaling.csv"
TTLS=(3 7)
QUERIES=(
    "customers|get Customer"
    "open_offers|get Offer where status = \"open\""
    "active_power_sum|get MeterReading where readingType = \"activePower\" show @sum(value)"
)

mkdir -p "${RESULT_DIR}"
echo "peer_count,query_label,ttl,elapsed_seconds,peers_responded,rows_returned" > "${CSV_FILE}"

metric_count() {
    curl --silent --fail http://127.0.0.1:2112/metrics 2>/dev/null |
        awk '/^idss_query_peers_responded_count / {print $2; exit}' || echo 0
}

for peer_count in $(seq 2 "${MAX_PEERS}"); do
    for repeat in $(seq 1 "${REPEATS}"); do
        pushd "${SERVER_DIR}" >/dev/null
        ./start_peers.sh "${peer_count}" > "${RESULT_DIR}/peers-${peer_count}-${repeat}.log" 2>&1 &
        launcher_pid=$!
        trap 'kill "${launcher_pid}" 2>/dev/null || true' EXIT

        for attempt in $(seq 1 60); do
            peer_address=$(grep "First peer address:" "${RESULT_DIR}/peers-${peer_count}-${repeat}.log" | awk '{print $NF}' || true)
            [[ -n "${peer_address}" ]] && break
            if ! kill -0 "${launcher_pid}" 2>/dev/null; then
                echo "Peer launcher failed for ${peer_count} peers:" >&2
                cat "${RESULT_DIR}/peers-${peer_count}-${repeat}.log" >&2
                popd >/dev/null
                exit 1
            fi
            sleep 1
        done
        if [[ -z "${peer_address:-}" ]]; then
            echo "Unable to obtain a peer address for ${peer_count} peers" >&2
            cat "${RESULT_DIR}/peers-${peer_count}-${repeat}.log" >&2
            kill "${launcher_pid}" 2>/dev/null || true
            wait "${launcher_pid}" 2>/dev/null || true
            popd >/dev/null
            continue
        fi
        popd >/dev/null

        for ttl in "${TTLS[@]}"; do
            for query_spec in "${QUERIES[@]}"; do
                label=${query_spec%%|*}
                query=${query_spec#*|}
                rm -rf "${CLIENT_DIR}/results"
                before=$(metric_count)
                started=$(date +%s%N)
                pushd "${CLIENT_DIR}" >/dev/null
                printf '%s, %s\nexit\n' "${query}" "${ttl}" | go run . -role manager -s "${peer_address}" >/dev/null
                popd >/dev/null
                finished=$(date +%s%N)
                after=$(metric_count)
                elapsed=$(awk -v start="${started}" -v end="${finished}" 'BEGIN { printf "%.6f", (end - start) / 1000000000 }')
                peers_responded=$((after - before))
                result_file=$(find "${CLIENT_DIR}/results" -type f -name '*.xml' | head -n 1)
                rows_returned=$(grep -c '<result>' "${result_file}")
                echo "${peer_count},${label},${ttl},${elapsed},${peers_responded},${rows_returned}" >> "${CSV_FILE}"
            done
        done

        kill "${launcher_pid}" 2>/dev/null || true
        wait "${launcher_pid}" 2>/dev/null || true
        trap - EXIT
    done
done

echo "Wrote scaling results to ${CSV_FILE}"
