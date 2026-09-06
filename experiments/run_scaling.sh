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
QUERIES=(
    "customers|get Customer"
    "open_offers|get Offer where status = \"open\""
    "active_power_sum|get MeterReading where readingType = \"activePower\" show @sum(value)"
)

mkdir -p "${RESULT_DIR}"
echo "peer_count,query_label,ttl,elapsed_seconds,peers_responded,rows_returned" > "${CSV_FILE}"

monotonic_seconds() {
    python3 -c 'import time; print(f"{time.monotonic():.9f}")'
}

for peer_count in $(seq 2 "${MAX_PEERS}"); do
    for repeat in $(seq 1 "${REPEATS}"); do
        pushd "${SERVER_DIR}" >/dev/null
        ./start_peers.sh "${peer_count}" > "${RESULT_DIR}/peers-${peer_count}-${repeat}.log" 2>&1 &
        launcher_pid=$!
        trap 'kill "${launcher_pid}" 2>/dev/null || true' EXIT

        for attempt in $(seq 1 60); do
            peer_address=$(grep "First peer address:" "${RESULT_DIR}/peers-${peer_count}-${repeat}.log" | awk '{print $NF}' || true)
            if [[ -n "${peer_address}" ]] && grep -q "All peers have joined the overlay." "${RESULT_DIR}/peers-${peer_count}-${repeat}.log"; then
                break
            fi
            if ! kill -0 "${launcher_pid}" 2>/dev/null; then
                echo "Peer launcher failed for ${peer_count} peers:" >&2
                cat "${RESULT_DIR}/peers-${peer_count}-${repeat}.log" >&2
                popd >/dev/null
                exit 1
            fi
            sleep 1
        done
        if [[ -z "${peer_address:-}" ]]; then
            echo "Peers did not become ready for ${peer_count} peers" >&2
            cat "${RESULT_DIR}/peers-${peer_count}-${repeat}.log" >&2
            kill "${launcher_pid}" 2>/dev/null || true
            wait "${launcher_pid}" 2>/dev/null || true
            popd >/dev/null
            exit 1
        fi
        mapfile -t peer_ids < <(grep 'Peer [0-9][0-9]* launched with ID ' "${RESULT_DIR}/peers-${peer_count}-${repeat}.log" | awk '{print $NF}')
        ttl_limit=1
        ttl_levels=0
        while (( ttl_limit < peer_count )); do
            ttl_limit=$((ttl_limit * 2))
            ttl_levels=$((ttl_levels + 1))
        done
        ttl_limit=$((ttl_levels + 2))
        popd >/dev/null

        for query_spec in "${QUERIES[@]}"; do
            label=${query_spec%%|*}
            query=${query_spec#*|}
            for ttl in $(seq 1 "${ttl_limit}"); do
                rm -rf "${CLIENT_DIR}/results"
                client_output=$(mktemp)
                started=$(monotonic_seconds)
                pushd "${CLIENT_DIR}" >/dev/null
                if ! printf '%s, %s\nexit\n' "${query}" "${ttl}" | go run . -role manager -s "${peer_address}" >"${client_output}" 2>&1; then
                    echo "Client query failed for ${label} with TTL ${ttl}" >&2
                    cat "${client_output}" >&2
                    popd >/dev/null
                    rm -f "${client_output}"
                    exit 1
                fi
                popd >/dev/null
                finished=$(monotonic_seconds)
                elapsed=$(awk -v start="${started}" -v end="${finished}" 'BEGIN { value = end - start; if (value < 0) value = 0; printf "%.6f", value }')
                uqi=$(sed -n 's/.*UQI:[[:space:]]*\([^[:space:]]*\).*/\1/p' "${client_output}" | head -n 1)
                result_file=$(find "${CLIENT_DIR}/results" -type f -name '*.xml' | head -n 1)
                if [[ -z "${result_file}" ]]; then
                    echo "Client produced no XML result for ${label} with TTL ${ttl}" >&2
                    cat "${client_output}" >&2
                    rm -f "${client_output}"
                    exit 1
                fi
                rows_returned=$(sed -n 's:.*<resultCount>\([0-9][0-9]*\)</resultCount>.*:\1:p' "${result_file}" | head -n 1)
                rows_returned=${rows_returned:-0}
                if [[ -n "${uqi}" ]]; then
                    peers_responded=0
                    for peer_id in "${peer_ids[@]}"; do
                        peer_log="${SERVER_DIR}/logs/${peer_id}.log"
                        if grep -q -F "${uqi}" "${peer_log}" 2>/dev/null; then
                            peers_responded=$((peers_responded + 1))
                        fi
                    done
                else
                    echo "Could not extract query UQI for ${label} with TTL ${ttl}" >&2
                    peers_responded=0
                fi
                echo "${peer_count},${label},${ttl},${elapsed},${peers_responded},${rows_returned}" >> "${CSV_FILE}"
                rm -f "${client_output}"

                if (( peers_responded >= peer_count )); then
                    break
                fi
            done
        done

        kill "${launcher_pid}" 2>/dev/null || true
        wait "${launcher_pid}" 2>/dev/null || true
        trap - EXIT
    done
done

echo "Wrote scaling results to ${CSV_FILE}"
