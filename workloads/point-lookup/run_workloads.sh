#!/usr/bin/env bash
# run_workloads.sh
# Usage: ./run_workloads.sh <total_conn>
#   export ADMIN_URI="postgresql://db:secret@172.18.0.250:26257/defaultdb?sslmode=prefer,..."
#   export TEST_URI_LIST="postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer,..."
#   export TEST_NAME="initial_test"
#   export CONN_TYPE="direct"  # or "pooling" (overrides auto-detection based on TXN_POOLONG)
#   export TXN_POOLONG="true"
# Example: ./run_workloads.sh 256 8

set -euo pipefail

IFS=',' read -r -a TEST_URIS <<< "${TEST_URI_LIST}"
if [[ "${#TEST_URIS[@]}" -eq 0 ]]; then
  echo "ERROR: TEST_URI_LIST is empty"
  exit 1
fi

total_conn=${1:-512}                # total connections target
num_workers=${2:-${#TEST_URIS[@]}}  # number of worker containers to launch
duration=${duration:-10}            # test length (minutes)
loops=${loops:-2048}                # number of executions per worker

# Use env vars or defaults
ADMIN_URI=${ADMIN_URI:-"postgresql://db:secret@192.168.0.1:26257/defaultdb?sslmode=prefer"}
TEST_NAME=${TEST_NAME:-"default"}
CONN_TYPE=${CONN_TYPE:-"direct"}
TXN_POOLONG=${TXN_POOLONG:-false}

# Other tunables
min_batch_size=${min_batch_size:-10}
max_batch_size=${max_batch_size:-100}
delay=${delay:-10000}

# workload files can be overridden via env
HOTSPOT_WORKLOAD=${HOTSPOT_WORKLOAD:-"transactionsHotspot.py"}
SCAN_SHAPE_WORKLOAD=${SCAN_SHAPE_WORKLOAD:-"transactionsScanShape.py"}
CONCURRENCY_WORKLOAD=${CONCURRENCY_WORKLOAD:-"transactionsConcurrency.py"}
STORAGE_WORKLOAD=${STORAGE_WORKLOAD:-"transactionsStorage.py"}
REGION_WORKLOAD=${REGION_WORKLOAD:-"transactionsRegion.py"}

# Derived
conns_per_worker=$(( (total_conn + num_workers - 1) / num_workers ))
ts="$(date +%Y%m%d_%H%M%S)"
marker='^run_name[[:space:]]'

mkdir -p logs

# wrap the logic in a reusable function
run_phase() {
  local workload_file="$1"   # e.g. transactionsHotspot.py
  local label="$2"           # e.g. hotspot

  local aggregate="logs/aggregate_summary_${CONN_TYPE}_${TEST_NAME}_${label}_${ts}.log"

  echo
  echo "=== Running phase '${label}' with workload '${workload_file}' ==="
  echo "Launching $num_workers containers ($conns_per_worker conns each) for test ${CONN_TYPE} ${TEST_NAME} (${label})"

  # phase-local arrays
  local -a ids=()
  local -a names=()
  local -a logs=()

  for i in $(seq 1 "$num_workers"); do
    BASE_URI="${TEST_URIS[$(( (i-1) % ${#TEST_URIS[@]} ))]}"

    # Replace localhost or 127.0.0.1 with host.docker.internal for Docker container
    BASE_URI="${BASE_URI//127.0.0.1/host.docker.internal}"
    BASE_URI="${BASE_URI//localhost/host.docker.internal}"

    # Extract everything before ? (so we can replace db name)
    URI_NO_PARAMS="${BASE_URI%%\?*}"
    URI_PARAMS=""
    if [[ "$BASE_URI" == *\?* ]]; then
      URI_PARAMS="?${BASE_URI#*\?}"
    fi

    # Replace database name with phase label
    # Assumes URI format .../dbname
    URI_PREFIX="${URI_NO_PARAMS%/*}"
    URI="${URI_PREFIX}/${label}${URI_PARAMS}"
    echo "Starting worker $i using URI: $URI"

    local run_name="${CONN_TYPE}_${TEST_NAME}_${label}_${ts}_w${i}"
    local name="dbw-${label}-${i}"
    names+=("$name")
    local log="logs/results_${run_name}.log"
    logs+=("$log")

    # switch between duration or iterations
    #       -d $(( ${duration} * 60 )) \
    #       -i ${loops} \
    local id
    id=$(docker run -d --name "$name" --network dcp-net \
      -v "$(pwd)/../../certs:/certs:ro" \
      --add-host=host.docker.internal:host-gateway \
      -e PYTHONUNBUFFERED=1 \
      -v "$PWD:/work" -w /work python:3.11.6 bash -lc "
        set -euo pipefail
        mkdir -p /work/logs
        apt-get install -y ca-certificates openssl
        update-ca-certificates

        echo \"[INFO] \$(date) Worker ${i} (${label}): starting pip bootstrap\" | tee -a /work/${log%.log}_build.log
        python -m pip install --upgrade pip setuptools wheel 2>&1 | stdbuf -oL -eL tee -a /work/${log%.log}_build.log

        echo \"[INFO] \$(date) Worker ${i} (${label}): installing runner deps\" | tee -a /work/${log%.log}_build.log
        pip install -r requirements-runner.txt 2>&1 | stdbuf -oL -eL tee -a /work/${log%.log}_build.log

        echo \"[INFO] \$(date) Worker ${i} (${label}): launching workload\" | tee -a /work/${log}
        # sleep 600000 &  # prevent container exit for debugging
        stdbuf -oL -eL dbworkload run \
          -w ${workload_file} \
          -c ${conns_per_worker} \
          -i ${loops} \
          --uri '${URI}' \
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

  # --- Compute phase start/end from per-worker logs (min start_time, max end_time) ---
  local phase_start=""
  local phase_end=""

  for i in $(seq 1 "$num_workers"); do
    local log="${logs[$((i-1))]}"

    # Extract timestamps from each worker log (format: YYYY-MM-DD HH:MM:SS)
    local w_start
    local w_end
    w_start=$(grep -m1 '^start_time[[:space:]]\{1,\}' "$log" | awk '{print $2" "$3}' || true)
    w_end=$(grep -m1 '^end_time[[:space:]]\{1,\}' "$log"   | awk '{print $2" "$3}' || true)

    # Skip if missing (defensive)
    [[ -z "$w_start" || -z "$w_end" ]] && continue

    # Track min start_time
    if [[ -z "$phase_start" || "$w_start" < "$phase_start" ]]; then
      phase_start="$w_start"
    fi

    # Track max end_time
    if [[ -z "$phase_end" || "$w_end" > "$phase_end" ]]; then
      phase_end="$w_end"
    fi
  done

  if [[ -z "$phase_start" || -z "$phase_end" ]]; then
    echo "WARN: Could not determine phase_start/phase_end from worker logs; skipping test_runs insert."
  else
    echo "Phase window for '${label}': start=${phase_start} end=${phase_end}"
  fi

  # --- Derive app_name from workload file ---
  # e.g. transactionsConcurrency.py -> Transactionsconcurrency
  local app_name="${workload_file%.py}" # remove .py extension
  app_name="${app_name,,}"              # convert to lowercase
  app_name="${app_name^}"               # capitalize first letter

  # connection type: check CONN_TYPE or hardcode direct/pooling based on txn pooling enabled
  local connection_type="${CONN_TYPE}"
  if [[ ! "$connection_type" =~ ^(direct|pooling)$ ]]; then
    if [[ "${TXN_POOLONG}" == "true" ]]; then
      connection_type="pooling"
    else
      connection_type="direct"
    fi
  fi

  # --- Insert a record into defaultdb.test_runs using ADMIN_URI ---
  if [[ -n "$phase_start" && -n "$phase_end" ]]; then
    local insert_base="${ADMIN_URI}"

    # we can connect locally (outside docker), so DO NOT replace localhost here.
    # But we DO want to force the DB to defaultdb for the insert.
    local insert_no_params="${insert_base%%\?*}"
    local insert_params=""
    if [[ "$insert_base" == *\?* ]]; then
      insert_params="?${insert_base#*\?}"
    fi
    local insert_prefix="${insert_no_params%/*}"
    local insert_uri="${insert_prefix}/defaultdb${insert_params}"

    # Insert the phase window row
    cockroach sql --url "${insert_uri}" -e "
      INSERT INTO defaultdb.test_runs
        (phase, database_name, app_name, connection_type, start_ts, end_ts, test_name, notes)
      VALUES
        ('${label}', '${label}', '${app_name}', '${connection_type}',
         '${phase_start}', '${phase_end}',
         '${TEST_NAME}', 'workload_file=${workload_file}, workers=${num_workers}, conns_per_worker=${conns_per_worker}, loops=${loops}');
    "

    echo "Inserted test_runs row for phase '${label}' into defaultdb.test_runs"
  fi

  echo "Cleaning up containers for phase '${label}'..."
  for id in "${ids[@]}"; do
    docker rm -fv "$id" >/dev/null 2>&1 || true
  done

  echo "Phase '${label}' done. Summary saved to ${aggregate}"
}

reconfigure_db_endpoint() {
  local label="$1"
  echo "Reconfiguring database for next phase with name '${label}'..."
  (
    cd ../../
    python controller.py \
      --ssh-user debian \
      --ssh-key ./my-safe-directory/dev \
      --dns-zone dcp-test.crdb.com \
      --root-cert skip \
      --start-nodes skip \
      --skip-init \
      --skip-haproxy \
      --certs-dir ./certs/crdb-dcp-test \
      --ca-key ./my-safe-directory/ca.key \
      --auth-mode cert \
      --num-connections 96 \
      --database ${label} \
      --pgb-port 5432 \
      --db-port 26257 \
      --pgb-client-user jleelong
  )
}

verify_db_endpoint() {
  local URI="$1"
  local label="$2"
  local max_attempts=30
  local attempt=1

  # Extract everything before ? (so we can replace db name)
  URI_NO_PARAMS="${URI%%\?*}"
  URI_PARAMS=""
  if [[ "$URI" == *\?* ]]; then
    URI_PARAMS="?${URI#*\?}"
  fi

  # Replace database name with phase label
  # Assumes URI format .../dbname
  URI_PREFIX="${URI_NO_PARAMS%/*}"
  URI="${URI_PREFIX}/${label}${URI_PARAMS}"

  echo "Waiting for database endpoint ${URI} to become ready..."

  while true; do
    if cockroach sql --url "$URI" -e "SELECT 1" >/dev/null 2>&1; then
      echo "Database endpoint ready."
      break
    fi

    if [[ $attempt -ge $max_attempts ]]; then
      echo "Database endpoint did not become ready in time."
      exit 1
    fi

    echo "Attempt $attempt failed, retrying..."
    sleep 2
    attempt=$((attempt+1))
  done
}

# Run Hotspot phase, then Scan Shape phase, Concurrency Hardening phase, and finally Storage Optimization phase

echo "Running Hotspot workload first..."
if [[ "${CONN_TYPE}" == "pooling" ]]; then
  reconfigure_db_endpoint "hotspot"
  verify_db_endpoint "${TEST_URIS[0]}" "hotspot"
fi
run_phase "${HOTSPOT_WORKLOAD}" "hotspot"

if [[ "${CONN_TYPE}" == "pooling" ]]; then
  reconfigure_db_endpoint "scan_shape"
  verify_db_endpoint "${TEST_URIS[0]}" "scan_shape"
fi
echo "Sleeping two minutes before starting Scan Shape workload..."
sleep 120
run_phase "${SCAN_SHAPE_WORKLOAD}" "scan_shape"

if [[ "${CONN_TYPE}" == "pooling" ]]; then
  reconfigure_db_endpoint "concurrency"
  verify_db_endpoint "${TEST_URIS[0]}" "concurrency"
fi
echo "Sleeping two minutes before starting Concurrency Hardening workload..."
sleep 120
run_phase "${CONCURRENCY_WORKLOAD}" "concurrency"

if [[ "${CONN_TYPE}" == "pooling" ]]; then
  reconfigure_db_endpoint "storage"
  verify_db_endpoint "${TEST_URIS[0]}" "storage"
fi
echo "Sleeping two minutes before starting Storage Optimization workload..."
sleep 120
run_phase "${STORAGE_WORKLOAD}" "storage"

if [[ "${CONN_TYPE}" == "pooling" ]]; then
  reconfigure_db_endpoint "region"
  verify_db_endpoint "${TEST_URIS[0]}" "region"
fi
echo "Sleeping two minutes before starting Multi-Region Locality workload..."
sleep 120
run_phase "${REGION_WORKLOAD}" "region"
echo "All phases complete."
