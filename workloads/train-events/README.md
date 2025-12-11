# Train Events
This workload simulates the ingestion, processing, state-transition, and archival lifecycle of train and track-management events using realistic multi-event ACID transactions that stress both concurrency control and JSON-heavy data paths.

It is a **multi-event transactional workload** designed to simulate the operational data flow of a modern railway control, dispatching, and track-management system.
It exercises a realistic mix of **read**, **write**, and **state-transition** operations that occur as trains move across a network, infrastructure states change, and control systems emit telemetry or directives.

The workload models three primary interaction patterns:

## 1. Event Ingestion Transactions
Each transaction inserts a **batch of 10–100 synthetic railway events**, such as route authorizations, signal clearances, speed restrictions, switch position changes, position updates, and infrastructure condition reports.
Every event is written atomically alongside a corresponding status record, simulating upstream publish or capture systems generating operational messages.

## 2. Event Processing Transactions
Batches of events in PENDING or PROCESSING states are selected with **row-level locking**, updated, and advanced through their lifecycle.

The workload includes:
- **FOR UPDATE** row locking
- Application of business logic modifications to the event payload
- State machine transitions (e.g., PENDING → PROCESSING → COMPLETE)

This represents downstream consumers such as dispatch systems, safety logic, or orchestration services that process operational rail messages concurrently.

## 3. Archival Transactions
Events that reach a terminal state are **bulk-archived** into a history table and then removed from the primary tables as part of a single ACID transaction.
This simulates data movement pipelines—ETL, retention policies, or system rollups—that extract completed operational events to long-term storage.

## What This Workload Demonstrates
- **Contention behavior** under multi-row, multi-statement transactions
- **Impact of JSONB vs TEXT** for storing and processing nested operational documents
- **Concurrency control patterns** (locks, retries, write–write conflicts)
- **End-to-end lifecycle simulation** of operational messages in a real dispatching or control system
- **Mixed read/write access** across hot rows and rolling windows of recent events
- **Batch-oriented transactional throughput** similar to real event-driven systems

## Option 1: JSONB (generated columns + inverted index)
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

## Option 2: JSONB-Manual (explicit columns, no inverted index)
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

JSONB-Manual gives you the shape and flexibility of JSONB, but you're paying the storage costs without the benefit of .

## Option 3: TEXT (string payload + generated columns)
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

## Summary of Options
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

## Initial Schema
First we'll execute the sql to create a sample schema and load some data into it.
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -f ./workloads/train-events/initial-schema.sql
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -f ./workloads/train-events/populate-sample-data.sql
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
pip freeze > requirements.txt
sed -E '/^(pyobjc-core|pyobjc-framework-Cocoa|py2app|rumps|macholib|tensorflow-macos|tensorflow-metal)(=|==)/d' \
  requirements.txt > requirements-runner.txt
cd ../../
```

## Direct Connections
Then we can use our workload script to simulate the workload going directly against the database running on our host machine.
```
cd ./workloads/train-events
export TEST_URI="postgresql://pgb:secret@host.docker.internal:26257/defaultdb?sslmode=prefer"
export TEST_NAME="direct"
export TXN_POOLONG="false"
./run_workloads.sh 512 4
cd ../../
```
You can tail the files in the logs directory or open another terminal and run ```docker logs -f dbw-1```

A summary of the test results for one of the workers is outlined below...

### Using JSONB Fields
```
>>> Worker 2 (logs/results_direct_jsonb_20251205_145706_w2.log)
run_name       Transactionsjsonb.20251205_200518
start_time     2025-12-05 20:05:18
end_time       2025-12-05 21:20:07
test_duration  4489
-------------  ---------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬────────────┬────────────┬────────────┬──────────────┬──────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │    p50(ms) │    p90(ms) │    p95(ms) │      p99(ms) │      max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼────────────┼────────────┼────────────┼──────────────┼──────────────┤
│     4,489 │ __cycle__ │       128 │     2,048 │           0 │ 235,245.13 │ 113,206.62 │ 604,262.01 │ 908,883.74 │ 1,528,382.15 │ 3,570,055.79 │
│     4,489 │ add       │       128 │     2,048 │           0 │  26,336.08 │  14,481.14 │  67,278.95 │ 104,525.78 │   137,686.78 │   187,292.17 │
│     4,489 │ archive   │       128 │     2,048 │           0 │  11,692.34 │   2,589.12 │  23,553.94 │  45,738.02 │   104,572.07 │   765,235.72 │
│     4,489 │ process   │       128 │     2,048 │           0 │ 197,110.51 │  81,868.00 │ 547,268.41 │ 848,393.07 │ 1,481,179.72 │ 3,389,565.89 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴────────────┴────────────┴────────────┴──────────────┴──────────────┘

Parameter      Value
-------------  --------------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsJsonb.py
conn_params    {'conninfo': 'postgresql://pgb:secret@host.docker.internal:26257/defaultdb?sslmode=prefer&application_name=Transactionsjsonb', 'autocommit': True}
conn_extras    {}
concurrency    128
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 100, 'txn_pooling': False}
```

### Versus Manual JSONB
```
>>> Worker 2 (logs/results_direct_manual_20251205_145706_w2.log)
run_name       Transactionsmanual.20251205_213022
start_time     2025-12-05 21:30:22
end_time       2025-12-05 21:44:21
test_duration  839
-------------  ----------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬────────────┬────────────┬────────────┬────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │    p90(ms) │    p95(ms) │    p99(ms) │    max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼────────────┼────────────┼────────────┼────────────┤
│       839 │ __cycle__ │       128 │     2,048 │           2 │  46,614.11 │ 25,231.53 │ 116,763.49 │ 158,155.35 │ 250,885.12 │ 412,646.54 │
│       839 │ add       │       128 │     2,048 │           2 │   2,911.16 │  1,645.64 │   7,452.17 │   9,401.98 │  16,640.97 │  19,200.30 │
│       839 │ archive   │       128 │     2,048 │           2 │   1,728.39 │    402.20 │   5,001.33 │   8,154.21 │  13,622.89 │  87,210.63 │
│       839 │ process   │       128 │     2,048 │           2 │  41,873.37 │ 20,207.13 │ 110,347.16 │ 148,431.61 │ 241,987.39 │ 412,164.05 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴────────────┴────────────┴────────────┴────────────┘

Parameter      Value
-------------  ---------------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsManual.py
conn_params    {'conninfo': 'postgresql://pgb:secret@host.docker.internal:26257/defaultdb?sslmode=prefer&application_name=Transactionsmanual', 'autocommit': True}
conn_extras    {}
concurrency    128
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 100, 'txn_pooling': False}
```

### Versus Text Fields
```
>>> Worker 2 (logs/results_direct_text_20251205_145706_w2.log)
run_name       Transactionstext.20251205_215423
start_time     2025-12-05 21:54:23
end_time       2025-12-05 22:05:47
test_duration  684
-------------  --------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬───────────┬────────────┬────────────┬────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │   p90(ms) │    p95(ms) │    p99(ms) │    max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼───────────┼────────────┼────────────┼────────────┤
│       684 │ __cycle__ │       128 │     2,048 │           2 │  36,799.64 │ 21,470.48 │ 92,092.69 │ 128,059.77 │ 211,407.33 │ 365,707.04 │
│       684 │ add       │       128 │     2,048 │           2 │   2,239.95 │    929.97 │  6,626.54 │   8,106.83 │  12,630.61 │  14,414.35 │
│       684 │ archive   │       128 │     2,048 │           2 │   3,700.88 │    677.17 │ 11,227.06 │  19,723.95 │  33,162.44 │ 110,019.48 │
│       684 │ process   │       128 │     2,048 │           2 │  30,754.82 │ 13,636.28 │ 82,801.00 │ 119,674.83 │ 208,971.75 │ 354,919.80 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴───────────┴────────────┴────────────┴────────────┘

Parameter      Value
-------------  -------------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsText.py
conn_params    {'conninfo': 'postgresql://pgb:secret@host.docker.internal:26257/defaultdb?sslmode=prefer&application_name=Transactionstext', 'autocommit': True}
conn_extras    {}
concurrency    128
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 100, 'txn_pooling': False}
```

## Managed Connections
We can simulate the workload again, this time using our PgBouncer HA cluster with transaction pooling, but we'll have to disable prepared statements due to connection multiplexing between clients.
```
cd ./workloads/train-events
export TEST_URI="postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer"
export TEST_NAME="pooling"
export TXN_POOLONG="true"
./run_workloads.sh 512 4
cd ../../
```
You can tail the files in the logs directory or open another terminal and run ```docker logs -f dbw-1```

And a summary of the test results for one of the workers is outlined below...

### Using JSONB Fields
```
>>> Worker 2 (logs/results_pooling_jsonb_20251205_171253_w2.log)
run_name       Transactionsjsonb.20251205_222037
start_time     2025-12-05 22:20:37
end_time       2025-12-05 23:38:12
test_duration  4655
-------------  ---------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬────────────┬────────────┬────────────┬────────────┬────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │    p50(ms) │    p90(ms) │    p95(ms) │    p99(ms) │    max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼────────────┼────────────┼────────────┼────────────┼────────────┤
│     4,655 │ __cycle__ │       128 │     2,048 │           0 │ 288,712.61 │ 286,967.91 │ 350,116.72 │ 359,988.52 │ 375,841.83 │ 475,557.90 │
│     4,655 │ add       │       128 │     2,048 │           0 │  84,617.07 │  81,069.30 │ 130,454.07 │ 144,062.69 │ 157,494.96 │ 168,891.45 │
│     4,655 │ archive   │       128 │     2,048 │           0 │  91,835.67 │  91,520.36 │ 116,591.05 │ 122,029.38 │ 132,162.56 │ 237,160.00 │
│     4,655 │ process   │       128 │     2,048 │           0 │ 112,159.25 │ 108,681.20 │ 147,030.65 │ 156,819.09 │ 167,366.98 │ 216,535.58 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴────────────┴────────────┴────────────┴────────────┴────────────┘

Parameter      Value
-------------  -----------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsJsonb.py
conn_params    {'conninfo': 'postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer&application_name=Transactionsjsonb', 'autocommit': True}
conn_extras    {}
concurrency    128
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 100, 'txn_pooling': True}
```

### Versus Manual JSONB
```
>>> Worker 2 (logs/results_pooling_manual_20251205_171253_w2.log)
run_name       Transactionsmanual.20251205_234809
start_time     2025-12-05 23:48:09
end_time       2025-12-06 00:05:27
test_duration  1038
-------------  ----------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬───────────┬───────────┬───────────┬───────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │   p90(ms) │   p95(ms) │   p99(ms) │   max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼───────────┼───────────┼───────────┼───────────┤
│     1,038 │ __cycle__ │       128 │     2,048 │           1 │  28,116.17 │ 28,110.66 │ 32,341.83 │ 33,583.76 │ 36,051.07 │ 38,847.89 │
│     1,038 │ add       │       128 │     2,048 │           1 │   4,891.30 │  4,741.76 │  7,081.66 │  8,026.68 │ 10,923.60 │ 17,005.71 │
│     1,038 │ archive   │       128 │     2,048 │           1 │  10,718.30 │ 10,518.72 │ 15,517.76 │ 16,769.48 │ 18,854.50 │ 20,523.07 │
│     1,038 │ process   │       128 │     2,048 │           1 │  12,406.43 │ 12,354.42 │ 16,327.43 │ 17,693.94 │ 20,130.97 │ 22,613.52 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴───────────┴───────────┴───────────┴───────────┘

Parameter      Value
-------------  ------------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsManual.py
conn_params    {'conninfo': 'postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer&application_name=Transactionsmanual', 'autocommit': True}
conn_extras    {}
concurrency    128
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 100, 'txn_pooling': True}
```

### Versus Text Fields
```
>>> Worker 2 (logs/results_pooling_text_20251205_171253_w2.log)
run_name       Transactionstext.20251206_031550
start_time     2025-12-06 03:15:50
end_time       2025-12-06 03:23:14
test_duration  444
-------------  --------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬───────────┬───────────┬───────────┬───────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │   p90(ms) │   p95(ms) │   p99(ms) │   max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼───────────┼───────────┼───────────┼───────────┤
│       444 │ __cycle__ │       128 │     2,048 │           4 │  25,978.44 │ 27,711.76 │ 34,419.31 │ 36,271.11 │ 40,399.79 │ 50,658.46 │
│       444 │ add       │       128 │     2,048 │           4 │   7,051.76 │  6,871.03 │ 11,928.27 │ 13,341.34 │ 16,424.42 │ 19,118.48 │
│       444 │ archive   │       128 │     2,048 │           4 │   8,393.76 │  8,083.32 │ 13,856.32 │ 15,753.56 │ 18,525.14 │ 19,966.52 │
│       444 │ process   │       128 │     2,048 │           4 │  10,432.22 │ 10,413.02 │ 15,619.18 │ 17,436.47 │ 20,112.72 │ 28,476.41 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴───────────┴───────────┴───────────┴───────────┴───────────┘

Parameter      Value
-------------  ----------------------------------------------------------------------------------------------------------------------------------------
workload_path  /work/transactionsText.py
conn_params    {'conninfo': 'postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer&application_name=Transactionstext', 'autocommit': True}
conn_extras    {}
concurrency    128
duration
iterations     2048
ramp           0
args           {'min_batch_size': 10, 'max_batch_size': 100, 'delay': 100, 'txn_pooling': True}
```

## Interpretation

### PART 1 - JSONB vs TEXT DATA TYPES

The output from our testing shows that JSONB with inverted indexes is not a good match for a high-throughput event queue with heavy writes and no nested JSON querying.  JSONB without inverted indexes or TEXT (without the generated fields) is absolutely the right approach for this workload.

**Mean Latency Comparison (per operation)**
| Operation | JSONB Mean (ms) | Manual Mean (ms) | Improvement Without Inverted Index | TEXT Mean (ms) | Improvement When Using TEXT |
| ------------- | ------------- | ------------- | ------------- | ------------- | ------------- |
| add | 26,336 ms | 2,911 ms | ~89% faster | 2,239 ms | ~23% faster |
| process | 197,110 ms | 41,873 ms | ~79% faster | 30,754 ms | ~27% faster |
| archive | 11,692 ms | 1,728 ms | ~85% faster | 3,700 ms | ~53% slower |
| cycle | 235,245 ms | 46,614 ms | ~80% faster | 36,799 ms | ~21% faster |

TEXT is *20-30%* faster depending on the phase, with the largest gains in the high-contention process stage.

**Why is JSONB so much slower?**

Using the CRDB metrics (statement activity & txn activity), several major factors become obvious:
- JSONB updates rewrite **large structured documents**, whereas TEXT just replaces a blob
- JSONB inverted indexes generate much higher **write amplification** (many more KV keys per write)
- JSONB transactions create significantly **more contention** and **longer lock hold times**
- JSONB ‘process’ operations often run ~1 second to multiple seconds per statement, while TEXT runs them in **tens of milliseconds**

From the database metrics:
- JSONB transactions show multi-minute average latencies in some cases, and heavy retry behavior (p99 5–10 seconds+)
- TEXT transactions remain sub-second to low-second even under load

### PART 2 - DIRECT vs MANAGED CONNECTIONS

The output from our testing shows that we get much better throughput with managed connections, even with the larger payloads.  However, longer transaction times will tie up 
those shared connections and you will see some latency while the client waits for a pooled connection to become available.  But it's far better to block at the client than to throttle performance on the database.  And we can always increase capacity if we need more connections.

**Mean Latencies (per operation)**
| Operation | Direct Cxn Mean | Managed Cxn Mean | Client Experience |
| ------------- | ------------- | ------------- | ------------- |
| add | 19,684 ms | 10,997 ms | ~44% faster |
| process | 130,594 ms | 12,436 ms | ~90% faster |
| archive | 17,618 ms | 10,810 ms | ~38% faster |
| cycle | 167,998 ms | 34,344 ms | ~80% faster |

If we had more capacity in the dababase we could increase our connection pool size to meet demand and would see sub-second response times in the client for most of these transactions.  But even without that, **managed pooling reduces client-perceived mean latency by ~40–90%**, depending on the operation.

The database behaves dramatically better when concurrency is controlled by PgBouncer, and the client sees faster completion of its total workload.  Here we did 2048 cycles in less than 10 minutes with managed transaction connections versus almost 52 minutes with session based connections.

**Why is pooling so effective here?**

Under Direct Connections:
- High KV execution latency
- High admission queue delays
- Spiky WAL fsync latency
- Many concurrent backends running expensive JSONB/TEXT updates
- Significant retry behavior even with TEXT

Under Managed Connections:
- Database sees only ~64 active sessions (instead of 512)
- Fewer active KV requests = **less contention**
- Shorter lock durations = **fewer restarts**
- Lower CPU scheduling pressure

**External pooling protects the database from the client’s concurrency**, so fewer queries overlap, causing fewer RB conflicts and much lower overall latency.

### SUMMARY OF WORKLOAD TESTING

A. JSONB vs TEXT Data Types:
- TEXT is **40–90%** faster across all operations
- JSONB’s write amplification, inverted-index maintenance, and structural costs significantly degrade throughput
- JSONB workloads show much higher contention and long-tail latency
- TEXT workloads show stable, predictable performance

**JSONB is not appropriate for a write-heavy OLTP queue workload.**

B. Direct vs Managed Connections:
- Managed pooling makes client operations **40–90%** faster on average
- Tail latency (p95/p99) improves **5–10×**
- Database metrics show smoother CPU usage, lower contention, higher throughput
- Client waits longer for pooled connections, but benefits from dramatically faster DB execution

**Managed pooling is the superior deployment model for this workload.**
