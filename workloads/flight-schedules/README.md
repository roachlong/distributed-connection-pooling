# Flight Schedules
This workload simulates the day-to-day lifecycle of airline flight schedules: generating flight plans, updating operational details, and serving read traffic that represents downstream planning, monitoring, and customer-facing systems.
It focuses on **high-frequency, lightweight read/write transactions** that stress indexing, row-level updates, and concurrent access to time-based operational data.

It is a **simple, high-velocity transactional workload** designed to model the core interactions of systems responsible for schedule publication, flight status updates, and operational synchronization across airline services.

The workload exercises three primary interaction patterns:

## 1. Schedule Generation Transactions
These transactions create new flight schedule entries, representing upstream schedule-planning systems that continuously publish changes.

Each insert models a single flight with structured attributes such as:
- Airline and flight number
- Origin / destination
- Planned departure and arrival times
- Equipment type
- Operational metadata (status, gate, terminal, etc.)

These operations simulate steady-state introduction of new flights into the operational window for a given day or period.

## 2. Schedule Update Transactions
Existing schedule records are selected and updated in place, simulating the frequent minor changes that occur throughout the day:
- Departure time adjustments
- Gate reassignments
- Equipment swaps
- Status changes (e.g., SCHEDULED → BOARDING → DEPARTED → ARRIVED)

These are **small, implicit read-modify-write** transactions:
1. Read the current schedule row
1. Apply a deterministic or randomized update
1. Write the updated row back atomically

They represent load patterns from real-world operational control centers, partner data feeds, and automated synchronization services.

## 3. Schedule Lookup Transactions
These transactions issue low-latency point reads or small range scans—queries commonly used by:
- Customer-facing flight-status APIs
- Gate/terminal display systems
- Mobile apps polling for updates
- Operational dashboards or planning tools

These reads stress index usage and concurrent access patterns across “hot” rows (near-term departure windows) without modifying data.

## What This Workload Demonstrates
- **Concurrent read/write behavior** on time-partitioned data such as upcoming flight legs
- **Update-heavy vs read-heavy balance**, reflecting real operational systems
- **Impact of concurrent updates** on single-row transactions and hot partitions
- **Index and storage efficiency** for schedule lookup patterns (origin/destination + time)
- **Real-world stress characteristics** of systems that must ingest updates continuously while serving high-volume read queries
- **Predictable ACID behavior** for small, frequent transactions
- **Throughput and latency characteristics** under mixed operational load

## Initial Schema
First we'll execute the sql to create a sample schema and load some data into it.
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -f ./workloads/flight-schedules/initial-schema.sql
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -f ./workloads/flight-schedules/populate-sample-data.sql
```

Then permission access to the tables for our pgbouncer client.
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -e """
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE defaultdb.* TO pgb;
"""
```

## dbworkload
This is a tool we use to simulate data flowing into cockroach, developed by one of our colleagues with python.  We can install the tool with ```pip3 install "dbworkload[postgres]"```, and then add it to your path.  On Mac or Linux with Bash you can use:
```
echo -e '\nexport PATH=`python3 -m site --user-base`/bin:$PATH' >> ~/.bashrc 
source ~/.bashrc
```
For Windows you can add the location of the dbworkload.exe file (i.e. C:\Users\myname\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.9_abcdefghijk99\LocalCache\local-packages\Python39\Scripts) to your Windows Path environment variable.  The pip command above should provide the exact path to your local python executables.

We can control the velocity and volume of the workload with a few properties described below.
* num_connections: we'll simulate the workload across a number of processes
* duration: the number of minutes for which we want to run the simulation
* iterations: or use the number of executions for each loop of the simulation
* schedule_freq: the percentage of cycles we want to make updates to the flight schedule
* status_freq: the percentage of cycles we want to make updates to flight status
* inventory_freq: the percentage of cycles we want to make updates to the available seating
* price_freq: the percentage of cycles we want to make updates to the ticket prices
* batch_size: the number of records we want to update in a single cycle
* delay: the number of milliseconds we should pause between transactions, so we don't overload admission controls

These parameters are set in the run_workloads.sh script.  We'll run multiple workers to simulate client apps (from a docker container) that run concurrently to process the total workload, each with a proportion of the total connection pool.  We'll pass the following parameters to the workload script.
* connection string: this is the uri we'll used to connect to the database
* test name: identifies the name of the test in the logs, i.e. direct
* txn poolimg: true if connections should be bound to the transaction, false for session
* total connections: the total number of connections we want to simulate across all workers
* num workers: the number of instances we want to spread the workload across

To execute the tests in docker we'll need to publish our python dependencies
```
cd ./workloads/flight-schedules
pip freeze > requirements.txt
sed -E '/^(pyobjc-core|pyobjc-framework-Cocoa|py2app|rumps|macholib|tensorflow-macos|tensorflow-metal)(=|==)/d' \
  requirements.txt > requirements-runner.txt
cd ../../
```

## Direct Connections
Then we can use our workload script to simulate the workload going directly against the database running on our host machine.
```
cd ./workloads/flight-schedules
export TEST_URI="postgresql://pgb:secret@host.docker.internal:26257/defaultdb?sslmode=prefer"
export TEST_NAME="direct"
export TXN_POOLONG="false"
./run_workloads.sh 1024 4
cd ../../
```
You can tail the files in the logs directory or open another terminal and run ```docker logs -f dbw-1```

A summary of the test results for one of the workers is outlined below...
```
>>> Worker 2 (logs/results_direct_20251124_081158_w2.log)
run_name       Transactions.20251124_131951
start_time     2025-11-24 13:19:51
end_time       2025-11-24 13:36:32
test_duration  1001
-------------  ----------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬───────────┬───────────┬───────────┬────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │   p90(ms) │   p95(ms) │   p99(ms) │    max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼───────────┼───────────┼───────────┼────────────┤
│     1,001 │ __cycle__ │       256 │     8,192 │           8 │  27,418.33 │ 25,233.66 │ 48,900.82 │ 57,079.37 │ 73,237.60 │ 135,899.16 │
│     1,001 │ inventory │       256 │     8,192 │           8 │  10,100.36 │  9,058.83 │ 22,061.79 │ 25,814.86 │ 36,782.19 │  52,089.72 │
│     1,001 │ price     │       256 │     8,192 │           8 │   3,302.30 │      0.02 │ 13,612.77 │ 19,371.13 │ 28,394.78 │  49,571.70 │
│     1,001 │ schedule  │       256 │     8,192 │           8 │   1,375.15 │      0.03 │  1,739.33 │ 12,267.97 │ 24,721.06 │  63,367.84 │
│     1,001 │ status    │       256 │     8,192 │           8 │  12,525.96 │ 11,044.13 │ 24,193.88 │ 28,637.84 │ 42,020.49 │  85,503.72 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴───────────┴───────────┴───────────┴────────────┘

Parameter      Value
-------------  ---------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactions.py
conn_params    {'conninfo': 'postgresql://pgb:secret@host.docker.internal:26257/defaultdb?sslmode=prefer&application_name=Transactions', 'autocommit': True}
conn_extras    {}
concurrency    256
duration
iterations     8192
ramp           0
args           {'schedule_freq': 10, 'status_freq': 90, 'inventory_freq': 75, 'price_freq': 25, 'batch_size': 64, 'delay': 100, 'txn_pooling': False}
```

## Managed Connections
We can simulate the workload again, this time using our PgBouncer HA cluster with transaction pooling, but we'll have to disable prepared statements due to connection multiplexing between clients.
```
cd ./workloads/flight-schedules
export TEST_URI="postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer"
export TEST_NAME="pooling"
export TXN_POOLONG="true"
./run_workloads.sh 1024 4
cd ../../
```
You can tail the files in the logs directory or open another terminal and run ```docker logs -f dbw-1```

And a summary of the test results for one of the workers is outlined below...
```
>>> Worker 2 (logs/results_pooling_20251124_112750_w2.log)
run_name       Transactions.20251124_163632
start_time     2025-11-24 16:36:32
end_time       2025-11-24 16:52:15
test_duration  943
-------------  ----------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬───────────┬───────────┬───────────┬───────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │   p90(ms) │   p95(ms) │   p99(ms) │   max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼───────────┼───────────┼───────────┼───────────┤
│       943 │ __cycle__ │       256 │     8,192 │           8 │  11,414.60 │ 12,042.02 │ 18,588.54 │ 19,930.02 │ 23,604.97 │ 30,338.06 │
│       943 │ inventory │       256 │     8,192 │           8 │   4,229.09 │  5,523.68 │  6,920.91 │  7,306.32 │  8,271.57 │  9,794.34 │
│       943 │ price     │       256 │     8,192 │           8 │   1,392.88 │      0.17 │  6,174.45 │  6,699.51 │  7,639.12 │  9,421.30 │
│       943 │ schedule  │       256 │     8,192 │           8 │     587.61 │      0.02 │  2,184.39 │  5,941.49 │  7,115.41 │  9,360.13 │
│       943 │ status    │       256 │     8,192 │           8 │   5,097.94 │  5,863.56 │  7,019.48 │  7,412.84 │  8,445.82 │  9,534.36 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴───────────┴───────────┴───────────┴───────────┘

Parameter      Value
-------------  -------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactions.py
conn_params    {'conninfo': 'postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer&application_name=Transactions', 'autocommit': True}
conn_extras    {}
concurrency    256
duration
iterations     8192
ramp           0
args           {'schedule_freq': 10, 'status_freq': 90, 'inventory_freq': 75, 'price_freq': 25, 'batch_size': 64, 'delay': 100, 'txn_pooling': True}
```

## Interpretation
From the client’s perspective, both the direct-connection and managed-connection (PgBouncer) executions completed the same total number of operations:
- **8192 operations per worker**
- **256 concurrent threads**
- **4 workers**
- **~1024 total concurrency**

But the client-side latency profile inside those fixed iterations is dramatically different:

### 1. Mean latency per operation drops substantially with PgBouncer

For example:

| Operation | Direct Mean (ms) | Pooled Mean (ms) | Improvement |
| ------------- | ------------- | ------------- | ------------- |
| cycle | 27,418 ms | 11,414 ms | ~58% faster |
| inventory | 10,100 ms | 4,229 ms | ~58% faster |
| price | 3,302 ms | 1,392 ms | ~58% faster |
| schedule | 1,375 ms | 587 ms | ~57% faster |
| status | 12,526 ms | 5,098 ms | ~59% faster |

That pattern is consistent across **all** event types:<br/>
client-side work is ~50–60% faster under pooled connections.

### 2. Tail latencies (p90–p99) shrink even more dramatically

Direct connections exhibit very large long-tail behavior:
- **p95 up to ~57 seconds**
- **p99 up to ~73 seconds**
 - **max > 2 minutes**

Under managed connections:
- **p95 typically under 8 seconds**
- **p99 under 10 seconds**
- **max ~9 seconds**

This is a **10×–20×** reduction in tail latency.

**Why?**

Because CockroachDB is handling far fewer active backend sessions, so:
- fewer competing goroutines
- fewer pgwire buffers
- fewer session-level memory contexts
- less scheduler pressure
- far fewer concurrent KV requests
- fewer write queues forming

The client sees more predictable, more stable response times as a direct result.
