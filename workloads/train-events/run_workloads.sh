#!/usr/bin/env bash
# run_workloads.sh
# Usage: ./run_workloads.sh <total_conn> <num_workers>
#   export TEST_URI="postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer"
#   export TEST_NAME="pooling"
#   export TXN_POOLONG="true"
# Example: ./run_workloads.sh 512 2

set -euo pipefail

total_conn=${1:-512}          # total connections target
num_workers=${2:-2}           # number of workload containers to launch
duration=${duration:-10}      # test length (minutes)
loops=${loops:-2048}          # number of executions per worker

# Use env vars or defaults
TEST_URI=${TEST_URI:-"postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer"}
TEST_NAME=${TEST_NAME:-"default"}
TXN_POOLONG=${TXN_POOLONG:-false}

# Other tunables
min_batch_size=${min_batch_size:-10}
max_batch_size=${max_batch_size:-100}
delay=${delay:-100}

# workload files can be overridden via env
JSONB_WORKLOAD=${JSONB_WORKLOAD:-"transactionsJsonb.py"}
MANUAL_WORKLOAD=${MANUAL_WORKLOAD:-"transactionsManual.py"}
TEXT_WORKLOAD=${TEXT_WORKLOAD:-"transactionsText.py"}

# Derived
conns_per_worker=$(( total_conn / num_workers ))
ts="$(date +%Y%m%d_%H%M%S)"
marker='^run_name[[:space:]]'

mkdir -p logs

# NEW: wrap the existing logic in a reusable function
run_phase() {
  local workload_file="$1"   # e.g. transactionsJsonb.py or transactionsText.py
  local label="$2"           # e.g. jsonb or text

  local aggregate="logs/aggregate_summary_${TEST_NAME}_${label}_${ts}.log"

  echo
  echo "=== Running phase '${label}' with workload '${workload_file}' ==="
  echo "Launching $num_workers containers ($conns_per_worker conns each) for test '${TEST_NAME}' (${label})"

  # phase-local arrays
  local -a ids=()
  local -a names=()
  local -a logs=()

  for i in $(seq 1 "$num_workers"); do
    local run_name="${TEST_NAME}_${label}_${ts}_w${i}"
    local name="dbw-${label}-${i}"
    names+=("$name")
    local log="logs/results_${run_name}.log"
    logs+=("$log")

    # switch between duration or iterations
    #       -d $(( ${duration} * 60 )) \
    #       -i ${loops} \
    local id
    id=$(docker run -d --name "$name" --network dcp-net \
      --add-host=host.docker.internal:host-gateway \
      -e PYTHONUNBUFFERED=1 \
      -v "$PWD:/work" -w /work python:3.12.7 bash -lc "
        set -euo pipefail
        mkdir -p /work/logs

        echo \"[INFO] \$(date) Worker ${i} (${label}): starting pip bootstrap\" | tee -a /work/${log%.log}_build.log
        python -m pip install --upgrade pip setuptools wheel 2>&1 | stdbuf -oL -eL tee -a /work/${log%.log}_build.log

        echo \"[INFO] \$(date) Worker ${i} (${label}): installing runner deps\" | tee -a /work/${log%.log}_build.log
        pip install -r requirements-runner.txt 2>&1 | stdbuf -oL -eL tee -a /work/${log%.log}_build.log

        echo \"[INFO] \$(date) Worker ${i} (${label}): launching workload\" | tee -a /work/${log}
        stdbuf -oL -eL dbworkload run \
          -w ${workload_file} \
          -c ${conns_per_worker} \
          -i ${loops} \
          --uri '${TEST_URI}' \
          --args '{
            \"min_batch_size\": ${min_batch_size},
            \"max_batch_size\": ${max_batch_size},
            \"delay\": ${delay},
            \"txn_pooling\": ${TXN_POOLONG}
          }' 2>&1 | stdbuf -oL -eL tee -a /work/${log}
      ")
    ids+=("$id")
    echo "Started worker $i (${label}) → container=$name id=$id • logs: $log"
  done

  echo "Waiting for all workers in phase '${label}'..."
  docker wait $(docker ps -aq --filter "name=dbw-${label}-") >/dev/null || true

  echo "Aggregating summaries for '${label}' into ${aggregate}..."
  : > "${aggregate}"

  for i in $(seq 1 "$num_workers"); do
    local log="${logs[$((i-1))]}"
    echo ">>> Worker ${i} (${log})" | tee -a "${aggregate}"

    if grep -qE "$marker" "$log"; then
      sed -n "/$marker/,\$p" "$log" | tee -a "${aggregate}"
    else
      echo "(marker not found in ${log}, dumping last 100 lines)" | tee -a "${aggregate}"
      tail -n 100 "${log}" | tee -a "${aggregate}"
    fi
    echo | tee -a "${aggregate}"
  done

  echo "Cleaning up containers for phase '${label}'..."
  for id in "${ids[@]}"; do
    docker rm -fv "$id" >/dev/null 2>&1 || true
  done

  echo "Phase '${label}' done. Summary saved to ${aggregate}"
}

# Run JSONB phase, then MANUAL phase, then TEXT phase

echo "Running JSON workload first..."
run_phase "${JSONB_WORKLOAD}" "jsonb"

echo "Sleeping two minutes before starting MANUAL workload..."
sleep 120

run_phase "${MANUAL_WORKLOAD}" "manual"

echo "Sleeping two minutes before starting TEXT workload..."
sleep 120

run_phase "${TEXT_WORKLOAD}" "text"

echo "All phases complete."
