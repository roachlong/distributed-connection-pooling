# Point Lookup

1. [Overview](#overview)
1. [What This Workload Demonstrates](#what-this-workload-demonstrates)
1. [Initial Setup](#initial-setup)
1. [Hotspot Pattern](#hotspot-pattern)
1. [Scan Shape](#scan-shape)
1. [Concurrency Hardening](#concurrency-hardening)
1. [Storage Optimization](#storage-optimization)
1. [Multi-Region Locality](#multi-region-locality)
1. [Interpretation](#interpretation)
1. [Performance Evaluation](#performance-evaluation)


## Overview
This workload reproduces a range-level hotspot scenario caused by a high-concurrency transactional outbox pattern in CockroachDB which is dependent on point lookups to verify the delivery and processing of message payloads.

The pattern consists of:
1. Insert into outbox inside a business transaction.
1. Immediately select the inserted row by id where is_published = false.
1. Update the row to mark it as published.

Under high concurrency and large payload sizes, this pattern can:
- Create heavy write pressure on a single index
- Cause rapid MVCC churn
- Trigger frequent range splits
- Increase compaction pressure
- Lead to blocked KV RPC requests

In extreme cases, single-row SELECT statements may block for extended periods waiting on a range replica.

## What This Workload Demonstrates
This workload demonstrates:
- How a point-lookup workload can become range-bound under write pressure
- How secondary index hotspots form
- How large payload sizes accelerate range growth
- The impact of concurrent INSERT → SELECT → UPDATE patterns

Once we identify and reproduce the hotspot pattern we'll solve the issue in three phases:

### Phase 1 — Remove the Scan Shape
eliminate the scan-shaped read plan:
1. Replace crdb_internal_mvcc_timestamp
1. Add STORING to partial index
1. Eliminate SELECT with guarded UPDATE

### Phase 2 — Concurrency Hardening
eliminate worker blocking via FOR UPDATE SKIP LOCKED:
1. Batch publishing
1. SKIP LOCKED
1. Limit working set

### Phase 3 — Storage / Range Optimization
improve cluster stability and throughput under sustained write load:
1. Split hot / cold columns
1. Payload compression
1. Pre-splitting

### Phase 4 — Multi-Region Locality
improve tail latency and reduce cross-region contention by ensuring reads/writes and transaction pushes stay in-region:
1. REGIONAL BY ROW tables
1. Region-scoped dispatcher
1. Per-region pre-splitting

## Initial Setup
We don't need a multi-region cluster to address the issue.  This failure mode is reproducible in a single-region cluster by creating:
- a high-concurrency workload where writers frequently touch the unpublished set, and
- readers perform a scan-shaped plan over that same span.
But I've setup a multi-region cluster to see the effects of amplified tail latency (remote leaseholders/WAN) and to test phase 4 with multi-region locality

First we'll create a collect metadata for each of our test runs.
```
cockroach sql --certs-dir ./certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -e """
CREATE TABLE IF NOT EXISTS defaultdb.test_runs (
  run_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  phase STRING NOT NULL,
  database_name STRING NOT NULL,
  app_name STRING NOT NULL,
  connection_type STRING NOT NULL,

  start_ts TIMESTAMPTZ NOT NULL,
  end_ts   TIMESTAMPTZ NOT NULL,

  test_name STRING NULL,
  notes STRING NULL
);

CREATE INDEX IF NOT EXISTS idx_test_runs_lookup
ON defaultdb.test_runs (created_at, phase, connection_type);
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
# if requirements.txt doesn't exist then $ pip freeze > requirements.txt
sed -E '/^(pyobjc-core|pyobjc-framework-Cocoa|py2app|rumps|macholib|tensorflow-macos|tensorflow-metal)(=|==)/d' \
  requirements.txt > requirements-runner.txt
```

### Direct Connections
First we'll execute the sql scripts to create databases for each phase of our test.
```
cd ./workloads/point-lookup
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./hotspot-schema.sql
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./scan-shape-schema.sql
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./concurrency-schema.sql
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./storage-schema.sql
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./region-schema.sql
```

Then we can use our workload script to simulate the workload going directly against the database running on our host machine.
```
export CRT="../../certs/crdb-dcp-test"
export ADM="pgb"
export ADMIN_URI="postgresql://${ADM}@db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${ADM}.crt&sslkey=${CRT}/client.${ADM}.key"
export USR="pgb"
export TEST_URI_LIST="\
postgresql://${USR}@db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key,\
postgresql://${USR}@db.us-west-1.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key,\
postgresql://${USR}@db.us-west-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key"
export TEST_NAME="march_8"
export CONN_TYPE="direct"
export TXN_POOLONG="false"
./run_workloads.sh 512
```
You can tail the files in the logs directory or open another terminal and run ```docker logs -f dbw-hotspot-1```

### Managed Connections
Then let's re-initialize our databases for each test phase.
```
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./hotspot-schema.sql
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./scan-shape-schema.sql
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./concurrency-schema.sql
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./storage-schema.sql
cockroach sql --certs-dir ../../certs/crdb-dcp-test --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -f ./region-schema.sql
```

And run the workload again, but this time using our PgBouncer HA cluster with transaction pooling.  We will have to disable prepared statements due to connection multiplexing between clients.
```
export CRT="../../certs/crdb-dcp-test"
export ADM="pgb"
export ADMIN_URI="postgresql://${ADM}@db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${ADM}.crt&sslkey=${CRT}/client.${ADM}.key"
export USR="jleelong"
export TEST_URI_LIST="\
postgresql://${USR}@pgb.us-east-2.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key,\
postgresql://${USR}@pgb.us-west-1.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key,\
postgresql://${USR}@pgb.us-west-2.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full&sslrootcert=${CRT}/ca.crt&sslcert=${CRT}/client.${USR}.crt&sslkey=${CRT}/client.${USR}.key"
export TEST_NAME="march_8"
export CONN_TYPE="pooling"
export TXN_POOLONG="true"
./run_workloads.sh 512
```
You can tail the files in the logs directory or open another terminal and run ```docker logs -f dbw-hotspot-1```

Review the following sections for an analysis of the results...

## Hotspot Pattern
This is intentionally “bad” for the workload: a single table + partial index, high concurrency, large payloads, and a point-lookup pattern that can amplify KV pressure and range stress.

This baseline reproduces the “outbox poll + publish” pattern where we:
- Insert event with large payload
- Immediately select by ID using partial index
- Immediately update to mark published

With the followinhg attributes:
- large payloads in-row
- a partial “unpublished” index
- an expensive crdb_internal_mvcc_timestamp read

Under load, this can cause:
- Heavy activity on a small set of ranges
- Frequent splits
- Replica lease contention
- KV RPC stalls

Expected results:
under enough concurrency + payload, if a leaseholder becomes overloaded, you can see
- high p99 latencies,
- slow KV RPCs,
- and instability

## Scan Shape
Our goal is to eliminate hotspot range scans on the partial-index that leads to long lock wait under heavy read/write patterns at the head of the index.

With our hotspot pattern our query shape could scan the entire unpublished index span and block behind conflicting writes.

We can fix this by:
1. Replacing crdb_internal_mvcc_timestamp with the application publish_timestamp column.
1. Adding a STORING (publish_timestamp) clause to the partial index so the query is index-only.
1. Eliminating the separate SELECT entirely by using a guarded UPDATE … RETURNING clause.

What It Addresses:
- Removes index-join.
- Reduces KV reads.
- Avoids span scan.
- Reduces lock wait exposure.
- Converts read-then-write into single-key write.

Expected Results:
- Dramatically lower p99 latency.
- Near-zero lock wait time for this statement.
- No more long waits on “slow replica RPC”.
- No more uncertainty retries caused by read-after-push.

## Concurrency Hardening
Our goal is to prevent blocking between publishers when multiple threads process unpublished rows.

So for phase 2 we're moving the processing model from “point lookup per message” to a dispatcher.

We accomplish this by implementing:
1. Batch selection
1. FOR UPDATE SKIP LOCKED
1. Publish in chunks

What It Addresses:
- Prevents workers from blocking behind a single locked row.
- Reduces per-message transaction overhead.
- Reduces transaction push loops.
- Reduces uncertainty interval retries.

This futher mitigates any blocked KV-level RPC on a specific range.

Expected Results:
- Higher throughput.
- Lower tail latency.
- Stable concurrency even under heavy load.
- No long lock waits.

## Storage Optimization
Our goal is to reduce write amplification, compaction pressure, and storage-level contention while preserving the concurrency improvements introduced in Phase 2.

Phase 3 separates hot queue metadata from cold payload data at the table level and provides better throughput by managing IO costs.

We accomplish this by optimizing storage-level behavior:
1. Keep the outbox table lean and single-family (hot path only).
1. Move the large payload column into a separate table (outbox_payload).
1. Optionally compress payload bytes at the application layer.
1. Optionally pre-split ranges to distribute growth across nodes.
1. Optionally apply regional locality in multi-region clusters.
1. Reduce IO amplification.
1. Reduce compaction cost.
1. Improve leaseholder responsiveness.

Even though Phase 1 fixed the main mechanism, this phase improves cluster resilience under sustained write pressure.

What It Addresses:
- Write amplification from large payload updates
- Range growth rate on hot metadata ranges
- LSM compaction overhead
- Store-level stalls that can delay leaseholder responsiveness

Expected Results:
- Lower background IO
- Reduced compaction CPU
- Lower write amplification
- More stable p99 latency under heavy insert load
- Better scaling under sustained throughput

We also introduce pre-splitting ranges, which is a range distribution optimization that:
- Avoids early co-location of writes in a single range
- Accelerates parallelism across nodes
- Reduces time-to-split during rapid growth
- Smooths ramp-up behavior

## Multi-Region Locality
Our goal is to reduce WAN-induced tail latency and cross-region transaction overhead while preserving the scan-shape fix from Phase 1, the dispatcher concurrency improvements from Phase 2, and the storage optimizations from Phase 3.

We accomplish this by making the outbox workload region-affine:
1. Outbox rows are homed in the region where they are created.
1. Publishing and claiming work is done locally in that same region.
1. Leaseholder reads/writes and PushTxn / lock resolution stay in-region when possible.

When we enable REGIONAL BY ROW a crdb_region column is introduced that defaults to gateway_region() so rows are placed near the node/region that receives the write.  Then in the dispatcher we can use WHERE crdb_region = gateway_region() to ensure workers only claim local rows.

What it addresses:
- WAN round trips caused by
  - leaseholders located in a different region than the gateway node
  - cross-region lock resolution / transaction pushes
- Unnecessary cross-region “ownership” of outbox rows
- Multi-region p99 spikes caused by remote leaseholders during publish cycles

Expected results:
- Lower p95/p99 latency for publish/dispatch in multi-region deployments
- Reduced cross-region RPC volume for the outbox workflow
- More predictable throughput as concurrency increases
- Improved resilience to transient WAN latency and multi-region clock uncertainty

## Interpretation
There are certain statistics and metrics we can use to evaluate the blocking RPC calls as a result of the hotspot pattern, and then use those same data points to show how we improve the pattern with each incremental change.

### Metrics Gathering
To measure the impact of each phase, we built a structured performance report that compares every test window using CockroachDB’s built-in telemetry.

Each phase was evaluated independently using the same workload and aligned time windows, ensuring clean comparisons.

After the test cycles complete we can run the following script to extract the metric information and generate comparative charts.
```
export DB_URL="postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full"
export DB_CERTS_DIR="../../certs/crdb-dcp-test"
python comparative-charts-generator.py march_08 hotspot direct
```

We focused on four categories of evidence.

<hr/>

### 1. Workload Throughput

**Question**: How much work did the system complete?

We measured:
- Total statement executions
- Effective transactions per second

Interpretation:
- Higher throughput indicates the system is doing more useful work.
- In some phases, the number of SQL statements changes (e.g., batching reduces statements per transaction), so throughput is interpreted alongside latency and contention.

<hr/>

### 2. Latency and Tail Behavior

**Question**: How fast did requests complete — especially under stress?

We evaluated:
- Average service latency (end-to-end SQL execution time)
- Execution latency (actual work time)
- A “tail latency” estimate (mean + 3×standard deviation)

Why tail latency matters:
- The original issue was not average latency — it was long-running, blocked RPCs.
- Improvements that reduce tail latency directly address that failure mode.

Key takeaway: ```Lower and more stable tail latency means fewer blocked operations and fewer cascading failures.```

<hr/>

### 3. Contention and Coordination Pressure

**Question**: How much time did transactions spend waiting on other transactions?

We measured:
- Total time transactions spent blocked
- Frequency of contention events
- Retry behavior

Why this matters:
- The hotspot pattern caused lock contention and range-level pressure.
- Reducing contention confirms we eliminated the root coordination bottleneck.

This is the most direct signal that the blocked RPC issue was resolved.

<hr/>

### 4. I/O and Data Movement

**Question**: How much disk and network work did the system perform?

We tracked:
- Rows read and written
- Bytes read from disk
- Sampled network traffic

Why this matters:
- Inefficient access patterns inflate disk reads.
- Large row widths increase write amplification.
- Cross-region operations increase network overhead.

Sharp reductions in bytes read and contention indicate more efficient architecture.

<hr/>

### Baseline Comparison

For clarity, every phase is compared to the original hotspot baseline:
- Throughput metrics: % change (higher is better)
- Latency, I/O, and contention metrics: % reduction (lower is better)

This makes the results easy to interpret:
- Which phase reduced disk pressure?
- Which phase eliminated contention?
- Which phase improved tail latency?
- What additional benefit did managed pooling provide?

Rather than focusing on internal metric names, the evaluation answers five practical questions:
- Did we eliminate blocked RPCs?
- Did we reduce lock contention?
- Did we reduce disk and replication pressure?
- Did we stabilize tail latency?
- Did throughput scale more predictably?

Each phase incrementally improved one of these dimensions, and the final architecture resolves all of them.

## Performance Evaluation

This section documents the performance evolution of the workload across five architectural phases, followed by an independent evaluation of managed (pooled) connections.

Each phase was executed under identical workload pressure (6 workers × 2048 iterations across three regions), and metrics were aligned precisely to the phase start/end timestamps.

The goal was to eliminate the original issue: ```Long-running RPCs blocked waiting on a KV range replica under hotspot pressure.```

<hr/>

### 1) Baseline — Hotspot Pattern
**Executive Summary**

The baseline configuration exhibited classic range-level overload behavior:
- High tail latency
- Significant KV admission queueing
- Replication backpressure
- Blocked replication streams
- Elevated WAL and commit latency
- High SQL contention

The system was not CPU-bound — it was **range-bound and coordination-bound**.

**Technical Findings**

During the baseline test window:
- KV Admission CPU slots exhausted frequently
- Foreground IO tokens exhausted
- Admission queue delay (p99) reached multiple seconds
- Blocked replication streams observed
- Replication flow token waits spiked
- WAL fsync latency (p99) elevated
- Log commit latency (p99) elevated
- Goroutine scheduling latency spiked
- Open SQL transactions peaked at 400–500
- SQL statement contention visible

This confirms the original diagnosis:
- Operations concentrated on the same key/range.
- Leaseholder replicas became the bottleneck.
- RPCs blocked waiting on replica coordination.
- Backpressure cascaded through admission and replication layers.

The hotspot pattern amplified coordination cost in a distributed environment.

<hr/>

### 2) Phase 1 — Scan Shape Improvements
**Executive Summary**

Removing the inefficient SELECT lookup reduced read amplification significantly but did not eliminate write-side hotspot pressure.

Performance improved at the storage layer, but coordination bottlenecks persisted.

**Technical Findings**

Changes implemented:
- Eliminated index lookup join
- Removed unnecessary SELECT round-trip

Observed impact:
- ~58% reduction in total bytes read
- Lower rowsRead metrics
- Reduced KV read time

However:
- KV admission spikes still present
- Replication backpressure still observed
- Admission queue delay (p99) still elevated
- SQL contention remained
- Tail latency did not collapse

**Conclusion**

Scan inefficiency was contributing to load, but the root problem was concentrated write pressure on a hot range.

<hr/>

### 3) Phase 2 — Concurrency Improvements
**Executive Summary**

Batching and concurrency changes improved logical efficiency but exposed the importance of controlling write parallelism.

Under uncontrolled direct connections, larger batched writes amplified lock duration and coordination pressure.

**Technical Findings**

Changes implemented:
- Batched updates
- Concurrency adjustments
- SKIP LOCKED-style dispatch pattern

Under direct connections:
- KV admission spikes intensified
- Replication flow control delays increased
- Blocked replication streams reappeared
- WAL fsync and commit latency spikes worsened
- Goroutine scheduling latency increased
- Tail latency spiked dramatically

Under managed/pooling connections:
- Admission spikes were smoother
- Replication queues shorter
- Tail latency significantly lower

**Conclusion**

Batching reduces round-trips but increases transaction weight.
Without concurrency control, heavier transactions amplify hotspot effects.

This phase demonstrated: ```The core issue was uncontrolled concurrency targeting a single hot range.```

<hr/>

### 4) Phase 3 — Storage Improvements
**Executive Summary**

Separating the payload into its own table dramatically reduced write amplification and hot-row pressure.

This phase eliminated the systemic range overload behavior.

**Technical Findings**

Changes implemented:
- Split payload from hot metadata table
- Reduced row width of frequently updated table
- Isolated large payload writes

Observed impact:
- ~99% reduction in bytes read
- KV admission CPU exhaustion disappeared
- IO token exhaustion minimized
- Replication flow token waits near zero
- Blocked replication streams eliminated
- WAL fsync p99 normalized
- Log commit latency stabilized
- Goroutine scheduling stable
- SQL contention nearly eliminated
- Tail latency collapsed for both connection types

This phase resolved the range-level overload.

The system was no longer:
- Range-bound
- IO-bound
- Replication-backpressured

It became steady-state and stable.

<hr/>

### 5) Phase 4 — Region Improvements
**Executive Summary**

Regional locality reduced cross-region coordination cost and further stabilized tail latency.

**Technical Findings**

Changes implemented:
- Regional-by-row locality
- Data placement aligned with workload region

Observed impact:
- Lower cross-region RPC cost
- Reduced replication send queue size
- Stable replication admission control
- Further reduction in tail latency
- Stable throughput
- No admission or replication pressure spikes

At this stage:
- No blocked RPC events observed
- No replication backpressure
- No KV admission exhaustion
- No systemic coordination bottlenecks

The architecture was now aligned with distributed best practices.

<hr/>

### 6) Managed Connections — External Pooling (Independent Evaluation)
**Executive Summary**

External connection pooling consistently improved tail latency and stability by limiting uncontrolled parallelism and connection churn.

Pooling did not change the workload logic or schema design. It improved stability by controlling concurrency pressure.

**Technical Findings**

Across all phases, managed connections:
- Reduced KV admission queue spikes
- Reduced replication flow token waits
- Reduced blocked replication streams
- Reduced WAL fsync p99 spikes
- Reduced log commit latency spikes
- Reduced goroutine scheduling latency
- Reduced runnable goroutines per CPU
- Reduced SQL contention
- Lowered open transaction count
- Improved tail latency
- Stabilized throughput

Pooling achieved this by:
- Capping active backend sessions
- Reducing connection churn
- Smoothing request bursts
- Preventing instantaneous overload of a single hot range

Important distinction:
- Pooling improved stability but did not eliminate the hotspot.
- Architectural changes (Phases 1–4) were required to fully resolve the blocked RPC condition.

<hr/>

### Final Outcome

By Phase 4:
- No blocked RPCs waiting on KV replicas
- No sustained KV admission queueing
- No replication backpressure
- No blocked replication streams
- Stable WAL and commit latency
- Stable goroutine scheduling
- Predictable tail latency
- Stable throughput

The original issue was not caused by a single query bug.

It was the emergent effect of:
- Lookup join on a hot partial index
- Concentrated write workload
- Wide row design
- Write amplification
- Unbounded direct concurrency
- Cross-region coordination overhead

Each phase systematically removed one layer of systemic pressure.

The final architecture:
- Narrow hot metadata table
- Payload isolated
- Concurrency controlled
- No lookup join
- Regionally colocated data
- Managed connection concurrency

The blocked RPC condition has been eliminated.

<hr/>

### Recommendation

1. For production workloads of this pattern:
1. Avoid lookup joins on hot partial indexes.
1. Keep frequently updated rows narrow.
1. Separate large payload columns from hot metadata.
1. Use SKIP LOCKED / dispatch patterns to prevent lock convoying.
1. Align data locality with request origin.
1. Use managed connection pooling to control concurrency pressure.
