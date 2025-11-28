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
loops=${loops:-8192}          # number of executions per worker

# Use env vars or defaults
TEST_URI=${TEST_URI:-"postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer"}
TEST_NAME=${TEST_NAME:-"default"}
TXN_POOLONG=${TXN_POOLONG:-false}

# Other tunables
schedule_freq=${schedule_freq:-10}
status_freq=${status_freq:-90}
inventory_freq=${inventory_freq:-75}
price_freq=${price_freq:-25}
batch_size=${batch_size:-64}
delay=${delay:-100}

# Derived
conns_per_worker=$(( total_conn / num_workers ))
ts="$(date +%Y%m%d_%H%M%S)"
marker='^run_name[[:space:]]'
aggregate="logs/aggregate_summary_${TEST_NAME}_${ts}.log"

mkdir -p logs
declare -a ids=()
declare -a names=()
declare -a logs=()
echo "Launching $num_workers containers ($conns_per_worker conns each) for test '${TEST_NAME}'"

for i in $(seq 1 "$num_workers"); do
  run_name="${TEST_NAME}_${ts}_w${i}"
  name="dbw-$i"
  names+=("$name")
  log="logs/results_${run_name}.log"
  logs+=("$log")

  # switch between duration or iterations
  #       -d $(( ${duration} * 60 )) \
  #       -i ${loops} \
  id=$(docker run -d --name "$name" --network dcp-net \
    --add-host=host.docker.internal:host-gateway \
    -e PYTHONUNBUFFERED=1 \
    -v "$PWD:/work" -w /work python:3.12.7 bash -lc "
      set -euo pipefail
      mkdir -p /work/logs

      echo \"[INFO] \$(date) Worker ${i}: starting pip bootstrap\" | tee -a /work/${log%.log}_build.log
      python -m pip install --upgrade pip setuptools wheel 2>&1 | stdbuf -oL -eL tee -a /work/${log%.log}_build.log

      echo \"[INFO] \$(date) Worker ${i}: installing runner deps\" | tee -a /work/${log%.log}_build.log
      pip install -r requirements-runner.txt 2>&1 | stdbuf -oL -eL tee -a /work/${log%.log}_build.log

      echo \"[INFO] \$(date) Worker ${i}: launching workload\" | tee -a /work/${log}
      stdbuf -oL -eL dbworkload run \
        -w transactions.py \
        -c ${conns_per_worker} \
        -i ${loops} \
        --uri '${TEST_URI}' \
        --args '{
          \"schedule_freq\": ${schedule_freq},
          \"status_freq\": ${status_freq},
          \"inventory_freq\": ${inventory_freq},
          \"price_freq\": ${price_freq},
          \"batch_size\": ${batch_size},
          \"delay\": ${delay},
          \"txn_pooling\": ${TXN_POOLONG}
        }' 2>&1 | stdbuf -oL -eL tee -a /work/${log}
    ")
  ids+=("$id")
  echo "Started worker $i → container=$name id=$id • logs: $log"
done

cleanup() {
  echo "Cleaning up containers..."
  # Stop any still-running; ignore errors
  for id in "${ids[@]}"; do docker rm -fv "$id" >/dev/null 2>&1 || true; done
}
trap cleanup INT TERM EXIT

echo "Waiting for all workers..."
docker wait $(docker ps -aq --filter "name=dbw-") >/dev/null

echo "Aggregating summaries into ${aggregate}..."
: > "${aggregate}"

for i in $(seq 1 "$num_workers"); do
  log="${logs[$((i-1))]}"
  echo ">>> Worker ${i} (${log})" | tee -a "${aggregate}"

  if grep -qE "$marker" "$log"; then
    sed -n "/$marker/,\$p" "$log" | tee -a "${aggregate}"
  else
    echo "(marker not found in ${log}, dumping last 100 lines)" | tee -a "${aggregate}"
    tail -n 100 "${log}" | tee -a "${aggregate}"
  fi
  echo | tee -a "${aggregate}"
done

cleanup
trap - INT TERM EXIT
echo "Done. Summary saved to ${aggregate}"
