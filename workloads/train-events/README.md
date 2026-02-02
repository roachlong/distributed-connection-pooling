# Train Events

1. [Overview](#overview)
1. [What This Workload Demonstrates](#what-this-workload-demonstrates)
1. [Initial Setup](#initial-setup)
1. [Direct Connections](#direct-connections)
1. [Managed Connections](#managed-connections)
1. [Interpretation](#interpretation)

## Overview
This workload simulates the ingestion, processing, state-transition, and archival lifecycle of train and track-management events using realistic multi-event ACID transactions that stress both concurrency control and JSON-heavy data paths.

It is a **multi-event transactional workload** designed to simulate the operational data flow of a modern railway control, dispatching, and track-management system.
It exercises a realistic mix of **read**, **write**, and **state-transition** operations that occur as trains move across a network, infrastructure states change, and control systems emit telemetry or directives.

The workload models three primary interaction patterns:

### 1. Event Ingestion Transactions
Each transaction inserts a **batch of 10–100 synthetic railway events**, such as route authorizations, signal clearances, speed restrictions, switch position changes, position updates, and infrastructure condition reports.
Every event is written atomically alongside a corresponding status record, simulating upstream publish or capture systems generating operational messages.

### 2. Event Processing Transactions
Batches of events in PENDING or PROCESSING states are selected with **row-level locking**, updated, and advanced through their lifecycle.

The workload includes:
- **FOR UPDATE** row locking
- Application of business logic modifications to the event payload
- State machine transitions (e.g., PENDING → PROCESSING → COMPLETE)

This represents downstream consumers such as dispatch systems, safety logic, or orchestration services that process operational rail messages concurrently.

### 3. Archival Transactions
Events that reach a terminal state are **bulk-archived** into a history table and then removed from the primary tables as part of a single ACID transaction.
This simulates data movement pipelines—ETL, retention policies, or system rollups—that extract completed operational events to long-term storage.

## What This Workload Demonstrates
- **Contention behavior** under multi-row, multi-statement transactions
- **Impact of JSONB vs TEXT** for storing and processing nested operational documents
- **Concurrency control patterns** (locks, retries, write–write conflicts)
- **End-to-end lifecycle simulation** of operational messages in a real dispatching or control system
- **Mixed read/write access** across hot rows and rolling windows of recent events
- **Batch-oriented transactional throughput** similar to real event-driven systems

### Option 1: JSONB (generated columns + inverted index)
**Best for**: Flexible schema, deep JSON querying, analytics on nested structures.

**Benefits**
- Automatic extraction of important fields via **generated columns** (event_type, authority_id, train_id).
- **Inverted index** enables fast, ad-hoc filtering on arbitrary JSON paths.
- Ideal when downstream systems need to query or filter deeply within the JSON payload.
- Schema changes require no DDL — the payload can evolve naturally.

**Trade-offs**
- **Highest write amplification**: inserting/updating a JSONB document touches many KV keys.
- **Most contention** under concurrency because the inverted index widens each transaction’s “footprint.”
- **Slowest throughput** and longest latency in write-heavy workloads.
- Payload updates require JSON tree rewrites rather than simple string replacement.

In write-heavy queue-style systems, JSONB provides powerful read/query features, but those features come with real performance cost.

### Option 2: JSONB-Manual (explicit columns, no inverted index)
**Best for**: Keeping structured JSON payloads while dramatically reducing write cost and contention.

**Benefits**
- Still stores payload as **JSONB**, preserving structure and downstream flexibility.
- Removes the inverted index, eliminating the largest source of write amplification.
- Flat columns (event_type, authority_id, train_id) are populated explicitly, leading to predictable indexing & performance.
- Faster than full JSONB on inserts/updates; lower contention footprint.

**Trade-offs**
- Application must **extract and populate flat columns manually**, adding logic complexity.
- No inverted index, therefore you cannot efficiently query arbitrary nested fields.
- JSON structure is preserved, but now acts mostly as a storage envelope, not an indexed query surface.
- And we're still encoding and decoding JSON, incurring additional overhead on every read and write operation.

JSONB-Manual gives you the shape and flexibility of JSONB, but you're paying the storage costs without the benefit of fast ad hoc query capabilities.

### Option 3: TEXT (string payload + generated columns)
**Best for**: High-throughput OLTP, event queues, ingestion scenarios, heavy write workloads.

**Benefits**
- **Fastest** of all three workloads by a large margin in high-concurrency environments.
- Almost no write amplification; replacing a string is cheap.
- Minimal contention footprint; best throughput under load.
- Generated columns still allow simple field extraction without touching the JSON payload structure.

**Trade-offs**
- Payload is stored as a raw string, CRDB will not understand the internal structure.
- No JSON operators or path-based filtering unless you cast to JSONB ad-hoc.
- No inverted index, therefore you must index fields explicitly (via generated columns or application logic).

TEXT is ideal when payloads are treated as **opaque blobs** and write throughput matters more than JSON queryability.

### Summary of Options
| Feature / Concern | JSONB (full) | JSONB-Manual | TEXT |
| ------------- | ------------- | ------------- | ------------- |
| Write speed | Slowest | Medium | Fastest |
| Contention footprint | Highest | Medium-Low | Lowest |
| Inverted index | Yes | No | No |
| Deep JSON querying | Best | None (unless manually added) | None (unless cast to JSONB) |
| Schema flexibility | High | Medium-High | Medium |
| App logic complexity | Lowest | Higher (manual extraction) | Lowest |
| Best use case | Analytics / deep filtering / JSON-native storage | Structured JSON storage without index overhead | High-throughput ingestion / queue workloads |

**JSONB** is the most flexible but the most expensive for writes.
**JSONB-Manual** is a balanced choice: structured payloads, lower write cost, predictable indexing.
**TEXT** is the clear winner for raw throughput and minimal contention in write-heavy pipelines.

## Initial Setup
First we'll execute the sql to create a sample schema and load some data into it.
```
cockroach sql --certs-dir ./certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./workloads/train-events/initial-schema.sql
cockroach sql --certs-dir ./certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./workloads/train-events/populate-sample-data.sql
```

Then permission access to the tables for our pgbouncer client.
```
cockroach sql --certs-dir ./certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -e """
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE defaultdb.* TO pgb;
"""
```

### dbworkload
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
* min_batch_size: the minimum number of events we want to process in a single transaction
* max_batch_size: the maximum number of events we want to process in a single transaction
* delay: the number of milliseconds we should pause between transactions, so we don't overload admission controls

These parameters are set in the run_workloads.sh script.  We'll run multiple workers to simulate client apps (from a docker container) that run concurrently to process the total workload, each with a proportion of the total connection pool.  We'll pass the following parameters to the workload script.
* connection string: this is the uri we'll used to connect to the database
* test name: identifies the name of the test in the logs, i.e. direct
* txn poolimg: true if connections should be bound to the transaction, false for session
* total connections: the total number of connections we want to simulate across all workers
* num workers: the number of instances we want to spread the workload across

To execute the tests in docker we'll need to publish our python dependencies
```
cd ./workloads/train-events
# if requirements.txt doesn't exist then $ pip freeze > requirements.txt
sed -E '/^(pyobjc-core|pyobjc-framework-Cocoa|py2app|rumps|macholib|tensorflow-macos|tensorflow-metal)(=|==)/d' \
  requirements.txt > requirements-runner.txt
```

## Direct Connections
Then we can use our workload script to simulate the workload going directly against the database running on our host machine.
```
export CRT="../../certs/crdb-dcp-test"
export USR="pgb"
export TEST_URI_LIST="\
postgresql://${USR}@db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key,\
postgresql://${USR}@db.us-west-1.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key,\
postgresql://${USR}@db.us-west-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key"
export TEST_NAME="direct"
export TXN_POOLONG="false"
./run_workloads.sh 512
```
You can tail the files in the logs directory or open another terminal and run ```docker logs -f dbw-jsonb-1```

A summary of the test results for one of the workers is outlined below...

### Using JSONB Fields
```
>>> Worker 1 (logs/results_direct_jsonb_20260201_232857_w1.log)
run_name       Transactionsjsonb.20260202_042917
start_time     2026-02-02 04:29:17
end_time       2026-02-02 05:05:42
test_duration  2185
-------------  ---------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬────────────┬────────────┬────────────┬──────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │    p90(ms) │    p95(ms) │    p99(ms) │      max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼────────────┼────────────┼────────────┼──────────────┤
│     2,185 │ __cycle__ │       171 │     1,881 │           0 │ 130,947.72 │ 88,293.49 │ 294,354.78 │ 388,867.11 │ 590,176.07 │ 1,299,944.92 │
│     2,185 │ add       │       171 │     2,216 │           1 │  14,818.45 │ 10,676.13 │  35,713.40 │  45,542.28 │  59,649.63 │    77,279.58 │
│     2,185 │ archive   │       171 │     1,881 │           0 │   8,165.49 │  2,655.28 │  17,530.39 │  46,628.53 │ 103,101.63 │   162,686.21 │
│     2,185 │ process   │       171 │     1,882 │           0 │  98,687.50 │ 54,092.30 │ 246,922.72 │ 344,313.71 │ 555,862.72 │ 1,286,094.99 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴────────────┴────────────┴────────────┴──────────────┘

Parameter      Value
-------------  ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsJsonb.py
conn_params    {'conninfo': 'postgresql://pgb@db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fca.crt&sslcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.pgb.crt&sslkey=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.pgb.key&application_name=Transactionsjsonb', 'autocommit': True}
conn_extras    {}
concurrency    171
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 10000, 'txn_pooling': False}
delay_stats    0
```

### Versus Manual JSONB
```
>>> Worker 1 (logs/results_direct_manual_20260201_232857_w1.log)
run_name       Transactionsmanual.20260202_050804
start_time     2026-02-02 05:08:04
end_time       2026-02-02 05:25:24
test_duration  1040
-------------  ----------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬────────────┬────────────┬────────────┬────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │    p90(ms) │    p95(ms) │    p99(ms) │    max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼────────────┼────────────┼────────────┼────────────┤
│     1,040 │ __cycle__ │       171 │     1,881 │           1 │  86,127.65 │ 41,062.49 │ 199,917.79 │ 377,881.49 │ 536,124.69 │ 694,552.46 │
│     1,040 │ add       │       171 │     1,891 │           1 │   5,753.35 │  3,104.25 │  11,062.73 │  23,863.38 │  49,736.04 │  72,341.72 │
│     1,040 │ archive   │       171 │     1,881 │           1 │  17,333.99 │    868.65 │  54,290.19 │ 102,910.74 │ 212,467.59 │ 444,729.41 │
│     1,040 │ process   │       171 │     1,881 │           1 │  53,247.14 │ 19,793.64 │ 132,338.65 │ 256,783.48 │ 436,152.77 │ 677,293.43 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴────────────┴────────────┴────────────┴────────────┘

Parameter      Value
-------------  ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsManual.py
conn_params    {'conninfo': 'postgresql://pgb@db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fca.crt&sslcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.pgb.crt&sslkey=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.pgb.key&application_name=Transactionsmanual', 'autocommit': True}
conn_extras    {}
concurrency    171
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 10000, 'txn_pooling': False}
delay_stats    0
```

### Versus Text Fields
```
>>> Worker 1 (logs/results_direct_text_20260201_232857_w1.log)
run_name       Transactionstext.20260202_052831
start_time     2026-02-02 05:28:31
end_time       2026-02-02 05:44:40
test_duration  969
-------------  --------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬────────────┬────────────┬────────────┬────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │    p90(ms) │    p95(ms) │    p99(ms) │    max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼────────────┼────────────┼────────────┼────────────┤
│       969 │ __cycle__ │       171 │     1,881 │           1 │  74,766.19 │ 35,619.72 │ 173,128.59 │ 397,310.80 │ 440,342.07 │ 553,196.50 │
│       969 │ add       │       171 │     1,901 │           1 │   5,947.70 │  3,944.38 │  11,744.32 │  19,251.79 │  42,798.03 │  75,650.74 │
│       969 │ archive   │       171 │     1,881 │           1 │   7,806.89 │    398.07 │   8,010.72 │  24,629.75 │ 244,791.75 │ 293,387.23 │
│       969 │ process   │       171 │     1,882 │           1 │  51,180.56 │ 19,720.89 │ 122,061.28 │ 225,816.58 │ 417,327.34 │ 537,779.37 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴────────────┴────────────┴────────────┴────────────┘

Parameter      Value
-------------  --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsText.py
conn_params    {'conninfo': 'postgresql://pgb@db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fca.crt&sslcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.pgb.crt&sslkey=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.pgb.key&application_name=Transactionstext', 'autocommit': True}
conn_extras    {}
concurrency    171
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 10000, 'txn_pooling': False}
delay_stats    0
```

## Managed Connections
We can simulate the workload again, this time using our PgBouncer HA cluster with transaction pooling, but we'll have to disable prepared statements due to connection multiplexing between clients.
```
export CRT="../../certs/crdb-dcp-test"
export USR="jleelong"
export TEST_URI_LIST="\
postgresql://${USR}@pgb.us-east-2.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key,\
postgresql://${USR}@pgb.us-west-1.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key,\
postgresql://${USR}@pgb.us-west-2.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key"
export TEST_NAME="pooling"
export TXN_POOLONG="true"
./run_workloads.sh 512
```
You can tail the files in the logs directory or open another terminal and run ```docker logs -f dbw-1```

And a summary of the test results for one of the workers is outlined below...

### Using JSONB Fields
```
>>> Worker 1 (logs/results_pooling_jsonb_20260202_011427_w1.log)
run_name       Transactionsjsonb.20260202_061444
start_time     2026-02-02 06:14:44
end_time       2026-02-02 06:34:00
test_duration  1156
-------------  ---------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬────────────┬────────────┬────────────┬────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │    p90(ms) │    p95(ms) │    p99(ms) │    max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼────────────┼────────────┼────────────┼────────────┤
│     1,156 │ __cycle__ │       171 │     1,881 │           1 │  99,408.55 │ 99,451.13 │ 119,121.07 │ 126,899.92 │ 145,570.78 │ 209,148.29 │
│     1,156 │ add       │       171 │     1,881 │           1 │  26,284.15 │ 26,327.28 │  36,550.17 │  40,186.75 │  46,196.64 │  50,994.82 │
│     1,156 │ archive   │       171 │     1,881 │           1 │  28,305.92 │ 27,663.31 │  38,959.11 │  42,900.66 │  62,931.77 │ 140,221.61 │
│     1,156 │ process   │       171 │     1,881 │           1 │  34,833.03 │ 34,301.52 │  44,371.93 │  49,921.53 │  67,357.89 │  92,954.13 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴────────────┴────────────┴────────────┴────────────┘

Parameter      Value
-------------  ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsJsonb.py
conn_params    {'conninfo': 'postgresql://jleelong@pgb.us-east-2.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full&sslrootcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fca.crt&sslcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.jleelong.crt&sslkey=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.jleelong.key&application_name=Transactionsjsonb', 'autocommit': True}
conn_extras    {}
concurrency    171
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 10000, 'txn_pooling': True}
delay_stats    0
```

### Versus Manual JSONB
```
>>> Worker 1 (logs/results_pooling_manual_20260202_011427_w1.log)
run_name       Transactionsmanual.20260202_063646
start_time     2026-02-02 06:36:46
end_time       2026-02-02 06:42:28
test_duration  342
-------------  ----------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬───────────┬───────────┬───────────┬───────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │   p90(ms) │   p95(ms) │   p99(ms) │   max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼───────────┼───────────┼───────────┼───────────┤
│       342 │ __cycle__ │       171 │     1,881 │           5 │  28,729.25 │ 28,257.46 │ 34,769.58 │ 36,614.50 │ 40,658.81 │ 45,822.07 │
│       342 │ add       │       171 │     1,881 │           5 │   5,373.32 │  5,342.45 │  7,462.92 │  8,391.69 │  9,711.30 │ 10,812.82 │
│       342 │ archive   │       171 │     1,881 │           5 │   5,005.44 │  4,639.17 │  7,798.14 │  8,946.84 │ 11,875.71 │ 20,616.78 │
│       342 │ process   │       171 │     1,881 │           5 │   8,354.88 │  7,930.99 │ 11,832.73 │ 13,065.06 │ 16,057.24 │ 23,312.62 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴───────────┴───────────┴───────────┴───────────┘

Parameter      Value
-------------  -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsManual.py
conn_params    {'conninfo': 'postgresql://jleelong@pgb.us-east-2.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full&sslrootcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fca.crt&sslcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.jleelong.crt&sslkey=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.jleelong.key&application_name=Transactionsmanual', 'autocommit': True}
conn_extras    {}
concurrency    171
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 10000, 'txn_pooling': True}
delay_stats    0
```

### Versus Text Fields
```
>>> Worker 1 (logs/results_pooling_text_20260202_011427_w1.log)
run_name       Transactionstext.20260202_064714
start_time     2026-02-02 06:47:14
end_time       2026-02-02 06:52:38
test_duration  324
-------------  --------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬───────────┬───────────┬───────────┬───────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │   p90(ms) │   p95(ms) │   p99(ms) │   max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼───────────┼───────────┼───────────┼───────────┤
│       324 │ __cycle__ │       171 │     1,881 │           5 │  26,788.40 │ 26,997.20 │ 30,572.55 │ 31,756.35 │ 35,379.15 │ 40,885.93 │
│       324 │ add       │       171 │     1,881 │           5 │   5,270.62 │  5,248.67 │  7,136.44 │  7,652.41 │  8,523.46 │  9,656.48 │
│       324 │ archive   │       171 │     1,881 │           5 │   4,610.94 │  4,554.18 │  6,328.49 │  7,130.06 │ 10,696.91 │ 18,935.66 │
│       324 │ process   │       171 │     1,881 │           5 │   6,915.02 │  6,903.93 │  9,025.60 │  9,633.00 │ 13,207.14 │ 19,699.65 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴───────────┴───────────┴───────────┴───────────┘

Parameter      Value
-------------  -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsText.py
conn_params    {'conninfo': 'postgresql://jleelong@pgb.us-east-2.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full&sslrootcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fca.crt&sslcert=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.jleelong.crt&sslkey=..%2F..%2Fcerts%2Fcrdb-dcp-test%2Fclient.jleelong.key&application_name=Transactionstext', 'autocommit': True}
conn_extras    {}
concurrency    171
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 10000, 'txn_pooling': True}
delay_stats    0
```

## Interpretation

### PART 1 - JSONB vs TEXT DATA TYPES

The output from our testing shows that JSONB with inverted indexes is not a good match for a high-throughput event queue with heavy writes and no nested JSON querying.  JSONB without inverted indexes or TEXT (without the generated fields) is absolutely the right approach for this workload.

**Mean Latency Comparison (per operation)**
| Operation | JSONB Mean (ms) | Manual Mean (ms) | Improvement Without Inverted Index | TEXT Mean (ms) | Improvement When Using TEXT |
| ------------- | ------------- | ------------- | ------------- | ------------- | ------------- |
| add | 14,818 ms | 5,753 ms | ~61% faster | 5,947 ms | ~3% slower |
| process | 98,687 ms | 53,247 ms | ~46% faster | 51,180 ms | ~4% faster |
| archive | 8,165 ms | 17,333 ms | ~112% slower | 7,806 ms | ~55% faster |

In our single region tests, TEXT was *20-30%* faster depending on the phase, with the largest gains in the high-contention process stage.  However, in multi-region, the dominant cost shifts away from payload representation (JSONB vs TEXT) and toward cross-region coordination, replication, and transaction latency.  So, in multi-region, coordination and replication dominate, so the payload representation becomes irrelevant once inverted indexes are removed.

But notice deletes with JSONB without inverted indexes are a costly operation.  While manual JSONB removes inverted-index overhead, which dramatically improves inserts and updates, deletes still pay the cost of rewriting large binary JSON values.  TEXT avoids that cost entirely, and inverted indexes partially offset it by accelerating delete targeting.  That’s why manual JSONB is fastest for add/process but slowest for archive.

**When is JSONB much slower?**

Using the CRDB metrics (statement activity & txn activity), several major factors become obvious:
- JSONB updates rewrite **large structured documents**, whereas TEXT just replaces a blob
- JSONB inverted indexes generate much higher **write amplification** (many more KV keys per write)
- JSONB transactions also create significantly **more contention** and **longer lock hold times**

From the single-region database metrics:
- JSONB transactions show multi-minute average latencies in some cases, and heavy retry behavior (p99 5–10 seconds+)
- TEXT transactions remain sub-second to low-second even under load

### PART 2 - DIRECT vs MANAGED CONNECTIONS

The output from our testing shows that we get much better throughput with managed connections, even with the larger payloads.  However, longer transaction times will tie up those shared connections and you will see some latency while the client waits for a pooled connection to become available.  But it's far better to block at the client than to throttle performance on the database.  And we can always increase capacity if we need more connections.

**Mean Latencies (per operation)**
| Operation | Direct Cxn Mean | Managed Cxn Mean | Client Experience |
| ------------- | ------------- | ------------- | ------------- |
| add | 5,947 ms | 5,270 ms | ~11% faster |
| process | 51,180 ms | 6,915 ms | ~86% faster |
| archive | 7,806 ms | 4,610 ms | ~41% faster |

If we had more capacity, we could safely increase the pool size **without reintroducing contention**, pushing these operations closer to sub-second latency.  But even without that, **managed pooling reduces client-perceived mean latency by ~40–90%**, depending on how contention-heavy the transaction is.

The database behaves dramatically better when concurrency is controlled by PgBouncer, and the client sees faster completion of its total workload.  Here we did 2048 cycles in less than 6 minutes with managed transaction connections versus over 16 minutes with session based connections.

**Why managed pooling is so effective here**

Managed pooling dramatically improves client-perceived latency when transactions are contention-heavy.

Under direct connections:
- Hundreds of concurrent SQL sessions execute long-running UPDATE/DELETE transactions
- Lock durations overlap heavily
- KV admission queues build up
- Transaction retries and restarts spike
- CPU scheduling and Raft coordination dominate latency

Under managed pooling:
- The database sees a bounded number of active transactions
- Write conflicts are reduced
- Lock hold times shrink
- Admission queues drain faster
- Overall work completes sooner even if clients wait briefly for a pooled connection

This effect is strongest for:
- processing long-running / update-heavy workloads
- moderate for archive / delete-heavy workloads
- less pronounced with append-heavy / low contention workloads

**External pooling protects the database from the client’s concurrency**, so fewer queries overlap, causing fewer RB conflicts and much lower overall latency.

### SUMMARY OF WORKLOAD TESTING

A. JSONB vs TEXT Data Types:
- JSONB with inverted indexes incurs severe write amplification and contention
- Removing inverted indexes yields large gains for both JSONB and TEXT
- TEXT provides additional benefits primarily in delete-heavy workloads
- In multi-region and high-latency environments, payload format is a second-order concern

**JSONB inverted indexes are the primary performance risk, not JSONB itself.**

B. Direct vs Managed Connections:
- Managed pooling reduces mean client latency by 40–90%, depending on transaction contention
- The largest gains occur for long-running, update-heavy transactions (process)
- Append-heavy transactions (add) benefit less, as they are not contention-bound
- Tail latency (p95/p99) improves 5–10×
- Database metrics show smoother CPU usage, lower contention, and higher throughput

**Managed pooling is the superior deployment model for contention-heavy OLTP workloads.**
