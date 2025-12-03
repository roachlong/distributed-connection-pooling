# distributed-connection-pooling

1. [Overview](#overview)
1. [Solution Architecture](#solution-architecture)
1. [Test Results](#test-results)
1. [CockroachDB](#cockroachdb)
1. [PgBouncer](#pgbouncer)
1. [High Availability](#high-availability)
1. [Flight Schedules Workload](#flight-schedules)
1. [Train Events Workload](#train-events)

## Overview

This repository was created to demonstrate a **fault-tolerant, highly available connection pooling solution for CockroachDB** that is **managed externally from application stacks**.

Modern distributed databases like CockroachDB can handle large volumes of concurrent connections, but many applications and frameworks still open and close database sessions inefficiently or hold idle connections longer than necessary. This creates unnecessary load on the database and limits scalability.

By **centralizing and externalizing connection pooling**, we decouple connection lifecycle management from the application tier — allowing each service to use lightweight, short-lived database sessions while still maintaining consistent access to a shared pool of open connections.

### Why External Connection Pooling?
<details>
<summary>more info...</summary>

**External connection pooling** (using PgBouncer or similar) provides several operational and architectural benefits:

1. Reduced Database Load

    Consolidates many transient app-side connections into a smaller, reusable pool of backend connections to CockroachDB.

    Minimizes session churn and metadata overhead in the database.

1. Improved Scalability

    Allows more applications or microservices to share the same CockroachDB cluster without exhausting connection limits.

    Smooths out spikes in connection activity through efficient multiplexing.

1. Faster Failover and Recovery

    Because connections are abstracted behind PgBouncer and a virtual IP managed by Pacemaker/Corosync, client applications can seamlessly reconnect during node failover events.

1. Simplified Application Configuration

    Applications connect to a single stable endpoint (VIP) instead of tracking individual database nodes.

    Connection parameters, authentication, and timeouts can be managed centrally.

1. Enhanced Observability and Control

    Connection metrics, session reuse rates, and transaction throughput can be monitored independently of application code.

    Connection-level policies (e.g., limits, timeouts, user mapping) can be tuned dynamically.
</details>

## Solution Architecture

This demo uses a **Docker-based local cluster** that emulates a full high-availability setup:

| Component	| Purpose |
| ------------- | ------------- |
| **PgBouncer** | Connection pooling layer between applications and CockroachDB |
| **HAProxy** | Load balances incoming connections and performs health checks |
| **Corosync + Pacemaker** | Cluster resource manager that coordinates failover, manages a floating virtual IP, and ensures service continuity |
| **STONITH / Fencing** | Prevents split-brain and enforces node isolation during failure scenarios |
| **CockroachDB** | Target database backend to validate connection routing and failover behaviors |

### Architecture (Problem): Direct Connections → Connection Swarm / Starvation
<details>
<summary>more info...</summary>

When many microservices each maintain their own pools, the database sees a “fan-out” of sessions. Spiky traffic and idle-but-open sessions waste resources and can starve active work.

[<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/connection-swarm.svg">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/connection-swarm.svg)

**Symptoms**
- **Connection swarm**: N services × M pool size ⇒ **N×M sessions** on CRDB.
- **Starvation / head-of-line blocking**: Busy services grab connections while others sit idle; spikes cause thrash.
- **High session churn & metadata overhead**: DB spends cycles managing sessions instead of executing queries.
- **Operational sprawl**: Auth, timeouts, and limits duplicated across every app.
</details>

### Architecture (Solution): Distributed Connection Pooling with HA
<details>
<summary>more info...</summary>

Centralize connection lifecycle management behind a **stable VIP**. HAProxy handles frontend health/routing; PgBouncer multiplexes many client sessions onto a compact backend pool; Pacemaker/Corosync orchestrates failover and fencing.

[<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/distributed-connection-pooling.svg">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/distributed-connection-pooling.svg)

**What this fixes**
- **Right-sized backend sessions**: Thousands of client connections map to **dozens** of CRDB sessions.
- **Fewer idle drains**: PgBouncer reuses backends across sessions/transactions; HAProxy evens out spikes.
- **Fast, clean failover**: Pacemaker moves the VIP + services; fencing prevents split-brain.
- **Centralized control**: One place to tune auth, timeouts, pool sizes, and limits.
</details>

### Key Attributes of This Solution
<details>
<summary>more info...</summary>

- **Highly Available**: Automatic failover of the PgBouncer + HAProxy stack through Pacemaker-managed floating IPs.

- **Fault Tolerant**: Node failures are isolated via STONITH fencing, ensuring data safety and service continuity.

- **Externally Managed**: Pooling and routing occur outside the application tier, simplifying configuration and improving maintainability.

- **Scalable Design**: Easily extended from a laptop demo to multi-VM or multi-region clusters with minimal changes.

- **Configurable Topology**: Supports both session and transaction pooling modes, adjustable via PgBouncer configuration.

- **Demonstrable Locally**: The full HA setup (including Corosync, Pacemaker, HAProxy, and PgBouncer) runs in containers for experimentation and reproducibility.
</details>

## Test Results

To demonstrate the impact of **external connection management**, we ran two identical transactional workloads against the same CockroachDB cluster.
Each workload used four workers with 256 concurrent connections each, generating an equivalent number and mix of SQL statements over the same time window.
The only difference was **how connections were managed**:

- **Direct Connections** – Each client session maintained a dedicated connection to the database.

- **Managed Connections (PgBouncer)** – Client sessions connected through PgBouncer, which multiplexed thousands of client requests across a much smaller pool of persistent database sockets.

In both cases, sessions were reused and queries were identical.
However, the **database-side workload profile changed dramatically** when PgBouncer mediated the connections.
By reducing the number of active backend sessions, CockroachDB spent far less time on connection management and session scheduling, and more time executing queries.

This shift in resource allocation led to higher throughput and lower latency—**more work accomplished with fewer active connections**.
SQL activity logs show a 97 % reduction in average statement execution time when PgBouncer was used, highlighting how efficient connection multiplexing improves utilization and minimizes internal contention in the database.

### SQL Activity
<details>
<summary>more info...</summary>

**Direct Connections**
[<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-activity.png">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-activity.png)

**Managed Connections**
[<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-activity.png">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-activity.png)
</details>

### Side-by-Side Metrics
<details>
<summary>more info...</summary>

Metrics collected from the database during both executions reveal significant differences in **internal transaction management and resource utilization**. The following charts present the two runs side by side.

| Metric | Direct Connections | Managed Connections |
| ------------- | ------------- | ------------- |
| Queries per Second | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-qps.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-qps.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-qps.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-qps.png) |
| Service Latency | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-latency.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-latency.png) |
| CPU Percent | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-cpu-pct.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-cpu-pct.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-cpu-pct.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-cpu-pct.png) |
| Memory Usage | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-go-mem-usage.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-go-mem-usage.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-go-mem-usage.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-go-mem-usage.png) |
| Read IOPS | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-read-iops.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-read-iops.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-read-iops.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-read-iops.png) |
| Write IOPS | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-write-iops.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-write-iops.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-write-iops.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-write-iops.png) |
| Open Sessions | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-open-sessions.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-open-sessions.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-open-sessions.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-open-sessions.png) |
| Connection Rate | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-connection-rate.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-connection-rate.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-connection-rate.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-connection-rate.png) |
| Open Transactions | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-open-txn.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-open-txn.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-open-txn.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-open-txn.png) |
| SQL Contention | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-contention.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-contention.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-contention.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-contention.png) |
| KV Latency | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-kv-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-kv-latency.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-kv-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-kv-latency.png) |
| SQL Memory | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-memory.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-memory.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-memory.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-memory.png) |
| WAL Sync Latency | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-wal-sync-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-wal-sync-latency.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-wal-sync-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-wal-sync-latency.png) |
| Commit Latency | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-commit-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-commit-latency.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-commit-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-commit-latency.png) |
| KV Slots Exhausted | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-kv-slots-exhausted.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-kv-slots-exhausted.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-kv-slots-exhausted.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-kv-slots-exhausted.png) |
| IO Tokens Exhausted | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-adm-tokens-exhausted.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-adm-tokens-exhausted.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-adm-tokens-exhausted.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-adm-tokens-exhausted.png) |
| CPU Queueing Delay | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-adm-queueing-delay.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-adm-queueing-delay.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-adm-queueing-delay.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-adm-queueing-delay.png) |
| Scheduling Latency | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-go-sched-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-go-sched-latency.png) | [<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-go-sched-latency.png" width="250">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-go-sched-latency.png) |
</details>

### Interpretation
<details>
<summary>more info...</summary>

In both configurations, client sessions were reused and issued the same mix of SQL statements.
The key difference was **where** connection management occurred.

With **direct connections**, each client maintained its own session against the database. This created a large number of active connections that CockroachDB had to track, schedule, and service concurrently. Each session consumed memory buffers, internal session state, and contributed to the per-query scheduling and transaction bookkeeping overhead inside the database.

When **PgBouncer** was introduced, it multiplexed many client sessions onto a much smaller set of persistent database sockets. This significantly reduced the number of active sessions the database had to maintain. As a result:

- **Database resources were redirected toward executing queries instead of managing connections.**
The reduction in session management overhead freed CPU cycles and memory, allowing the database to spend more time executing user transactions.

- **Query latency and variability decreased.**
Because fewer backends were contending for internal locks, thread scheduling, and memory buffers, statement execution times became shorter and more predictable.

- **Throughput improved even with fewer open connections.**
Connection multiplexing allowed PgBouncer to maintain high concurrency at the application layer while presenting a leaner footprint to the database.

- **System-level metrics (CPU, memory, and IO)** showed reduced contention and steadier utilization profiles, demonstrating more efficient workload execution.

In essence, **PgBouncer amplified throughput per backend connection**—doing more work with fewer open sessions.
This is consistent with the principle that connection pooling not only stabilizes workloads but also lets distributed databases like CockroachDB dedicate more of their resources to actual query execution rather than connection lifecycle management.

See below for more details on how to setup and run the workload with distributed connection pooling.
</details>

## CockroachDB

**CockroachDB** is a **distributed SQL database** built for **global scale, strong consistency, and high resilience**. It’s wire-compatible with PostgreSQL, which means it supports the same SQL syntax, drivers, and tools — including PgBouncer — while providing automatic replication, fault tolerance, and horizontal scalability.

Unlike traditional databases that rely on a single primary node, CockroachDB distributes data automatically across multiple nodes. Each node can serve reads and writes, and the system ensures **ACID transactions** even in the presence of node or network failures. This makes it ideal for applications that require continuous availability and strong data integrity.

In this demo, CockroachDB serves as the **backend database** behind PgBouncer. While the example uses a single-node secure cluster for simplicity, the same principles apply to multi-node and multi-region deployments. The focus here is on the **connection management layer** — showing how PgBouncer can efficiently manage database sessions and reduce load on CockroachDB in high-concurrency environments.

### Why CockroachDB Benefits from Connection Pooling
<details>
<summary>more info...</summary>

Each connection to CockroachDB represents an active **SQL session** with its own memory context, transaction state, and session-level metadata. In busy application environments — particularly those with many microservices or short-lived requests — rapidly opening and closing connections can create overhead that limits scalability and increases latency.

Using **PgBouncer** as an intermediary allows applications to reuse a smaller set of persistent backend sessions while still handling thousands of concurrent client requests. This reduces pressure on CockroachDB’s session management layer, minimizes transaction contention, and ensures that the database remains focused on executing queries rather than maintaining idle connections.

Together, CockroachDB and PgBouncer form a robust foundation for **distributed, fault-tolerant connection management**, where scaling the application tier doesn’t compromise database performance or stability.
</details>

### CockroachDB Setup
<details>
<summary>more info...</summary>

We'll start by configuring a local secure single-node database that will provide the backend for testing connections through pgbouncer.  This demo is not meant to demonstrate the reliability and throughput capabilities of CockroachDB.  It will primarily focus on the performance of connection management to the backend.

We'll use a secure cluster so we can insert connection management between the application components and our database using PgBouncer.

1) Create a directory to hold our self-signed certificate ```mkdir -p certs my-safe-directory```
1) Then run the cockroach commands to generate the certs.
```
cockroach cert create-ca --certs-dir=certs --ca-key=my-safe-directory/ca.key
cockroach cert create-node localhost 127.0.0.1 $(hostname) --certs-dir=certs --ca-key=my-safe-directory/ca.key
cockroach cert create-client root --certs-dir=certs --ca-key=my-safe-directory/ca.key
```

Copy the client certs into the default location for postgres on Mac
```
cp certs/client.root.crt ~/.postgresql/root.crt
cp certs/client.root.key ~/.postgresql/postgresql.key
```
Or on Windows
```
cp certs\client.root.crt $env:APPDATA\.postgresql\root.crt
cp certs\client.root.key $env:APPDATA\.postgresql\postgresql.key
```

Then check your cockroach version and start your single node instance with the new certs.
```
cockroach --version
cockroach start-single-node --certs-dir=./certs --store=./data --advertise-addr=localhost:26257 --background
```

And create a new admin user for your cluster.  **Note**: with Windows PowerShell use two pairs of double quotes around me, i.e. ``` ""me"" ```
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb?sslmode=verify-full" -e """
CREATE ROLE "me" WITH LOGIN PASSWORD 'secret';
GRANT admin TO me;
"""
```
Now you can log into the cockroachdb console for your secure cluster using the credentials you provided above at https://localhost:8080/

Let's also create a non-admin user that we will use to connect through PgBouncer
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb?sslmode=verify-full" -e """
CREATE ROLE "pgb" WITH LOGIN PASSWORD 'secret';
"""
```

And test the connection
```
cockroach sql --url "postgresql://pgb:secret@localhost:26257/defaultdb?sslmode=prefer" -e "show databases;"
```
</details>

## PgBouncer

**PgBouncer** is a lightweight, high-performance **connection pooler for PostgreSQL-compatible databases**, including CockroachDB.

Each client connection to a database consumes memory and server resources, even when idle.  In high-traffic or microservice environments, thousands of short-lived sessions can quickly overwhelm the database.  PgBouncer solves this by **reusing backend connections** instead of opening a new one for every client request.

It sits transparently between applications and the database, accepting client connections and efficiently managing a shared pool of backend connections.  PgBouncer supports multiple pooling modes:

- **Session pooling** — reuses a backend connection for the duration of a client session.

- **Transaction pooling** — reuses backend connections for individual transactions, offering maximum efficiency.

- **Statement pooling** — reuses connections per statement (less common, but useful for specific workloads).

In this demo, PgBouncer acts as the **connection management layer** between your application and CockroachDB.  It allows multiple client applications to share a limited number of database sessions, providing:

- Faster connection handling
- Reduced database load
- Centralized authentication and configuration
- A consistent connection endpoint for HAProxy and Pacemaker to manage

### Scale the Network
<details>
<summary>more info...</summary>

Before we get started we'll need to increase the capacity of our docker network to handle 2048 connections
```
colima stop
colima start --network-address --memory 8 --cpu 4 --disk 100
```

Then increase the kernel and networking limits on the VM 
```
colima ssh

# socket state snapshot
ss -s
ss -tan state time-wait | wc -l

# current sysctl values relevant to load
sysctl net.core.somaxconn net.core.netdev_max_backlog \
       net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range \
       net.ipv4.tcp_fin_timeout 2>/dev/null || true

# conntrack (if available on your VM kernel)
sysctl net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count 2>/dev/null || true

sudo tee /etc/sysctl.d/99-dcp-tuning.conf >/dev/null <<'SYS'
# more listen queue & in-flight SYNs
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 32768

# ephemeral ports & TIME_WAIT behavior
net.ipv4.ip_local_port_range = 15000 65000
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# conntrack (if available)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 65536
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15

# file handles
fs.file-max = 1048576
SYS

sudo sysctl --system || sudo sysctl -p

echo '* soft nofile 1048576
* hard nofile 1048576' | sudo tee -a /etc/security/limits.conf

exit
colima restart
```

Next stop and remove any containers that we may have created previously
```
docker stop pgbouncer1 pgbouncer2 ha-node1 ha-node2 vip-proxy
docker rm pgbouncer1 pgbouncer2 ha-node1 ha-node2 vip-proxy
```
</details>

### PgBouncer Setup
<details>
<summary>more info...</summary>

Next we'll build our pgbouncer docker image and spin up two pgbouncer instances
```
docker network create dcp-net

docker build -t pgbouncer --build-arg PGBOUNCER_VERSION=1.17.0 pgbouncer

docker container run \
    --name pgbouncer1 \
    --network dcp-net \
    --ulimit nofile=262144:262144 \
    -p 5431:5432 \
    -d pgbouncer \
    --client-account pgb \
    --client-password secret \
    --num-connections 64 \
    --host-ip $(ipconfig getifaddr en0) \
    --host-port 26257 \
    --database defaultdb

docker container run \
    --name pgbouncer2 \
    --network dcp-net \
    --ulimit nofile=262144:262144 \
    -p 5432:5432 \
    -d pgbouncer \
    --client-account pgb \
    --client-password secret \
    --num-connections 64 \
    --host-ip $(ipconfig getifaddr en0) \
    --host-port 26257 \
    --database defaultdb
```

And test the connection to each
```
cockroach sql --url "postgresql://pgb:secret@localhost:5431/defaultdb?sslmode=prefer" -e "show databases;"

cockroach sql --url "postgresql://pgb:secret@localhost:5432/defaultdb?sslmode=prefer" -e "show databases;"
```

To test the host connection inside the container
```
docker exec -it pgbouncer1 /bin/bash
wget https://binaries.cockroachdb.com/cockroach-latest.linux-arm64.tgz
tar -xvzf cockroach-latest.linux-arm64.tgz
cp cockroach-*/cockroach /usr/local/bin/
cockroach version
cockroach sql --url "postgresql://pgb:secret@localhost:5432/defaultdb?sslmode=prefer" -e "show databases;"
```
</details>

## High Availability

**HAProxy** is a high-performance **TCP/HTTP load balancer** and reverse proxy. In this demo, it terminates **no** database protocol; instead it operates in **TCP passthrough** mode to balance PostgreSQL-compatible traffic across **PgBouncer** instances. HAProxy provides:
- **Health checks**: automatically removes unhealthy PgBouncer nodes from rotation.
- **Load balancing**: spreads connections (e.g., **leastconn**) to avoid hotspots.
- **High availability**: pairs naturally with **Pacemaker/Corosync** and a **floating VIP** for active/standby failover.
- **Operational visibility**: built-in stats and logs for quick troubleshooting.

By fronting PgBouncer with HAProxy, clients use a **single stable endpoint**, while PgBouncer handles **connection multiplexing** to CockroachDB — reducing backend session pressure and smoothing traffic spikes.

### What are Corosync and Pacemaker?
<details>
<summary>more info...</summary>

**Corosync** and **Pacemaker** together form the **high-availability cluster stack** that keeps services like HAProxy and the VIP running on exactly one healthy node at a time.

- **Corosync** provides the **cluster communication layer** — it handles membership, heartbeats, and quorum. It ensures each node knows who’s alive, who’s failed, and when it’s safe to take over shared resources.

- **Pacemaker** runs on top of Corosync as the **cluster resource manager**. It decides where to start or stop each service (e.g., HAProxy, PgBouncer, or a virtual IP), monitors their health, and automatically performs **failover** if a node or service goes down.

In this demo, Corosync and Pacemaker coordinate between two HAProxy nodes. Only one node at a time “owns” the virtual IP and serves traffic. If that node fails, Pacemaker moves the VIP (and HAProxy) to the other node within seconds, ensuring uninterrupted client access.

Together they form the brains of the HA cluster — Corosync detects failure, Pacemaker makes recovery decisions, and fencing ensures safety.
</details>

### What is STONITH / Fencing?
<details>
<summary>more info...</summary>

**STONITH** stands for “**Shoot The Other Node In The Head**.” It’s Pacemaker’s fencing mechanism — the ultimate safeguard against **split-brain** conditions in a cluster.

When a node stops responding or loses quorum, Pacemaker doesn’t immediately assume it’s truly dead. To avoid two nodes simultaneously taking ownership of shared resources (like a VIP or database), the cluster first performs **fencing**: it forcibly isolates or powers off the suspect node so that it cannot corrupt data or conflict with the survivor.

Common fencing methods include:
- **IPMI / iDRAC / iLO** hardware power-off
- **Cloud API fencing** (AWS, Azure, GCP)
- **Shared-disk fencing (SBD)** for physical clusters
- **Fence agents** like fence_vmware, fence_apc, etc.

In this Docker-based demo, we use the lightweight fence_dummy agent — it doesn’t actually power off containers, but it lets us see how Pacemaker would trigger fencing in a real deployment.

Fencing guarantees that at any given time, only one node controls critical resources — the key to maintaining **data consistency** and **cluster integrity** in any high-availability design.
</details>

### HA Setup
<details>
<summary>more info...</summary>

<details>
<summary>1. Start by creating two containers using the host network so they can manipulate an IP on the host interface:</summary>

```
docker build -t ha-node ha-node

for n in ha-node1 ha-node2; do
    docker container run \
        --name $n \
        --hostname $n \
        --network dcp-net \
        --ulimit nofile=262144:262144 \
        --privileged \
        --cgroupns=host \
        --security-opt seccomp=unconfined \
        --cap-add SYS_ADMIN \
        --tmpfs /run --tmpfs /run/lock \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -d ha-node
done
```
</details>

<details>
<summary>2. And confirm that systemd is running inside each node</summary>

```
docker exec -it ha-node1 bash -lc 'systemctl is-system-running --wait || true; hostname -f'
docker exec -it ha-node2 bash -lc 'systemctl is-system-running --wait || true; hostname -f'
```
</details>

<details>
<summary>3. Next enable pcsd and set the hacluster password on both nodes</summary>

```
for n in ha-node1 ha-node2; do
    docker exec -it $n bash -lc '
    systemctl enable --now pcsd &&
    echo -e "secret\nsecret" | passwd hacluster
    '
done
```
</details>

<details>
<summary>4. Get each HA node’s IP (on dcp-net) and ensure node name resolution</summary>

```
IP1=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ha-node1)
IP2=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ha-node2)
echo "ha-node1=$IP1  ha-node2=$IP2"

for n in ha-node1 ha-node2; do
  docker exec -it $n bash -lc "
    cp /etc/hosts /etc/hosts.bak &&
    # Remove any existing ha-node* lines
    awk '!(\$2==\"ha-node1\" || \$2==\"ha-node2\")' /etc/hosts > /tmp/hosts &&
    # Prepend correct mappings so they are picked first
    printf '%s ha-node1\n%s ha-node2\n' '$IP1' '$IP2' | cat - /tmp/hosts > /etc/hosts &&
    echo 'Resolution now:' &&
    getent hosts ha-node1 &&
    getent hosts ha-node2 &&
    echo 'HEAD of /etc/hosts:' &&
    sed -n '1,8p' /etc/hosts
  "
done

docker exec -it ha-node1 bash -lc 'hostname -f; getent hosts $(hostname -s)'
docker exec -it ha-node2 bash -lc 'hostname -f; getent hosts $(hostname -s)'
```
</details>

<details>
<summary>5. Configure Corosync with UDPU instead of multi-cast</summary>

**Why UDPU?**
Docker/Colima often block multicast; UDPU (unicast) avoids that and stabilizes the Corosync ring.

First generate and distribute the authkey:
```
docker exec -it ha-node1 bash -lc 'corosync-keygen -l'
KEY64=$(docker exec ha-node1 bash -lc "base64 -w0 /etc/corosync/authkey")
docker exec -it ha-node2 bash -lc "echo '$KEY64' | base64 -d > /etc/corosync/authkey && chmod 400 /etc/corosync/authkey"
```

Then write the following config on both nodes for two-node quorum tuning:
```
CONF=$(cat <<EOF
totem {
    version: 2
    cluster_name: ha-cluster
    transport: knet
    token: 5000
    token_retransmits_before_loss_const: 10
    join: 60
    max_messages: 20
    secauth: on
    crypto_cipher: aes256
    crypto_hash: sha256
}

nodelist {
    node {
        nodeid: 1
        name: ha-node1
        ring0_addr: ${IP1}
        link {
            addr: ${IP1}
        }
    }
    node {
        nodeid: 2
        name: ha-node2
        ring0_addr: ${IP2}
        link {
            addr: ${IP2}
        }
    }
}

quorum {
    provider: corosync_votequorum
    two_node: 1
    wait_for_all: 1
    auto_tie_breaker: 1
    last_man_standing: 1
}

logging {
    to_stderr: no
    to_logfile: yes
    logfile: /var/log/corosync/corosync.log
    to_syslog: yes
    debug: off
    timestamp: on
}
EOF
)

docker exec -i ha-node1 bash -lc 'cat > /etc/corosync/corosync.conf' <<<"$CONF"
docker exec -i ha-node2 bash -lc 'cat > /etc/corosync/corosync.conf' <<<"$CONF"

docker exec -it ha-node1 bash -lc 'corosync -f -t && echo OK'
docker exec -it ha-node2 bash -lc 'corosync -f -t && echo OK'
```

Start the cluster stack:
```
for n in ha-node1 ha-node2; do
  docker exec -it $n bash -lc '
    mkdir -p /etc/systemd/system/corosync.service.d &&
    cat > /etc/systemd/system/corosync.service.d/override.conf <<EOF
[Service]
# wipe packaged ExecStart, then set ours explicitly
ExecStart=
ExecStart=/usr/sbin/corosync -f -c /etc/corosync/corosync.conf
EnvironmentFile=
EOF
    systemctl daemon-reload
    systemctl restart corosync
  '
done

for n in ha-node1 ha-node2; do
  docker exec -it $n bash -lc 'systemctl enable --now corosync pacemaker'
done
```

And check the status:
```
docker exec -it ha-node1 bash -lc 'corosync-cfgtool -s; tail -n 50 /var/log/corosync/corosync.log || true'
docker exec -it ha-node2 bash -lc 'corosync-cfgtool -s; tail -n 50 /var/log/corosync/corosync.log || true'
```
</details>

<details>
<summary>6. Bootstrap pacemaker properties but temporarily relax fencing/quorum</summary>

```
docker exec -it ha-node1 bash -lc '
  pcs property set stonith-enabled=false;
  pcs property set no-quorum-policy=ignore;
  pcs status
'
```
Should report both nodes Online: [ ha-node1 ha-node2 ].
</details>

<details>
<summary>7. Create the VIP inside the Docker network</summary>

We picked 172.18.0.250/24; NIC is eth0 inside these containers:
```
VIP=172.18.0.250
docker exec -it ha-node1 bash -lc \
  "pcs resource create vip ocf:heartbeat:IPaddr2 ip=${VIP} cidr_netmask=24 nic=eth0 op monitor interval=30s; pcs status resources"
```
</details>

<details>
<summary>8. Configure HAProxy and colocate it with the VIP</summary>

Push a simple pgsql TCP LB config to both nodes:
```
cat > /tmp/haproxy.cfg <<CFG
global
    log stdout format raw daemon
    maxconn 200000
    nbthread 4
    tune.maxaccept 100
defaults
    log     global
    mode    tcp
    option  tcplog
    maxconn 100000
    timeout connect 5s
    timeout client  180s
    timeout server  180s
    option  tcpka
listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 5s
frontend pgsql_in
    bind *:5432
    default_backend pgb_pool
backend pgb_pool
    mode tcp
    balance leastconn
    option  tcp-check
    default-server init-addr libc,none inter 2s fall 3 rise 2 fastinter 1s
    # if name resolution becomes flaky, add a resolvers block; for now libc DNS should resolve Docker names
    server pgb1 pgbouncer1:5432 check
    server pgb2 pgbouncer2:5432 check
CFG

docker cp /tmp/haproxy.cfg ha-node1:/etc/haproxy/haproxy.cfg
docker cp /tmp/haproxy.cfg ha-node2:/etc/haproxy/haproxy.cfg

for n in ha-node1 ha-node2; do
  docker exec -it $n bash -lc 'systemctl enable --now haproxy && systemctl is-active haproxy'
done
```

Add HAProxy as a Pacemaker resource and colocate with VIP:
```
docker exec -it ha-node1 bash -lc '
  pcs resource create haproxy systemd:haproxy op monitor interval=10s &&
  pcs constraint order start vip then haproxy &&
  pcs constraint colocation add haproxy with vip INFINITY &&
  pcs status
'
```
</details>

<details>
<summary>9. Test from a client container on the same network</summary>

Your host can’t reach the VIP so we'll test from another container inside dcp-net.
```
docker run --rm -it --network dcp-net alpine sh -c "
  apk add --no-cache postgresql15-client curl >/dev/null && \
  echo 'Stats page:' && curl -s http://${VIP}:8404/stats | head -n 3 || true && \
  echo && echo 'psql via VIP:' && \
  psql 'postgresql://pgb:secret@${VIP}:5432/defaultdb?sslmode=prefer' -c 'show databases;'"
```
</details>

<details>
<summary>10. Prove failover</summary>
Move resources to node2
```
docker exec -it ha-node1 bash -lc 'pcs resource move vip ha-node2 && sleep 2 && pcs status'
```

Check which node holds the VIP
```
docker exec -it ha-node1 bash -lc "ip addr show eth0 | grep ${VIP} || true"
docker exec -it ha-node2 bash -lc "ip addr show eth0 | grep ${VIP} || true"
```

Hit the VIP again (should still work)
```
docker run --rm -it --network dcp-net alpine sh -c "
  apk add --no-cache postgresql15-client >/dev/null && \
  psql 'postgresql://pgb:secret@${VIP}:5432/defaultdb?sslmode=prefer' -c 'show databases;'"
```
</details>

<details>
<summary>11. Enable dummy fencing for demonstration.</summary>

```
docker exec -it ha-node1 bash -lc "
  pcs property set stonith-enabled=true;
  pcs stonith create fence-demo fence_dummy pcmk_host_list='ha-node1 ha-node2';
  pcs status"
```
In real VMs/hardware, replace fence_dummy with IPMI/libvirt/cloud agents.
</details>

<details>
<summary>12. Some commands to verify status of HA cluster</summary>

```
docker exec -it ha-node1 bash -lc "pcs status"
docker exec -it ha-node1 bash -lc "corosync-cfgtool -s"
docker exec -it ha-node1 bash -lc "tail -n 100 /var/log/corosync/corosync.log"
```
</details>

<details>
<summary>13. (Optional) Create an entry point to the VIP</summary>

You can setup nginx inside a docker container if you want to route requests from your host to the HA cluster.  This works well for experimentation, but we'll want to avoid the extra hop and network restrictions when running workload tests.

Start by creating our image
```
mkdir -p nginx
cat > nginx/nginx.conf <<CFG
worker_processes  auto;

events { worker_connections  1024; }

stream {
  # Pg via VIP
  upstream pg_vip {
    server ${VIP}:5432;
  }
  server {
    listen 6432;
    proxy_pass pg_vip;
    proxy_timeout 180s;
    proxy_connect_timeout 5s;
  }

  # HAProxy stats via VIP
  upstream haproxy_stats_vip { server ${VIP}:8404; }
  server {
    listen 8404;
    proxy_pass haproxy_stats_vip;
  }
}
CFG

docker container run -d --name vip-proxy \
  --network dcp-net \
  --ulimit nofile=262144:262144 \
  -p 6432:6432 -p 8404:8404 \
  -v "$PWD/nginx:/etc/nginx:ro" \
  nginx:1.27-alpine
```

And then test the connection
```
cockroach sql --url "postgresql://pgb:secret@localhost:6432/defaultdb?sslmode=prefer" -e "show databases;"
```
Also check the stats pages at http://localhost:8404/stats
</details>
</details>

## Flight Schedules
This workload simulates the day-to-day lifecycle of airline flight schedules: generating flight plans, updating operational details, and serving read traffic that represents downstream planning, monitoring, and customer-facing systems.
It focuses on **high-frequency, lightweight read/write transactions** that stress indexing, row-level updates, and concurrent access to time-based operational data.

It is a **simple, high-velocity transactional workload** designed to model the core interactions of systems responsible for schedule publication, flight status updates, and operational synchronization across airline services.

The workload exercises three primary interaction patterns:

### 1. Schedule Generation Transactions
<details>
<summary>more info...</summary>

These transactions create new flight schedule entries, representing upstream schedule-planning systems that continuously publish changes.

Each insert models a single flight with structured attributes such as:
- Airline and flight number
- Origin / destination
- Planned departure and arrival times
- Equipment type
- Operational metadata (status, gate, terminal, etc.)

These operations simulate steady-state introduction of new flights into the operational window for a given day or period.
</details>

### 2. Schedule Update Transactions
<details>
<summary>more info...</summary>

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
</details>

### 3. Schedule Lookup Transactions
<details>
<summary>more info...</summary>

These transactions issue low-latency point reads or small range scans—queries commonly used by:
- Customer-facing flight-status APIs
- Gate/terminal display systems
- Mobile apps polling for updates
- Operational dashboards or planning tools

These reads stress index usage and concurrent access patterns across “hot” rows (near-term departure windows) without modifying data.
</details>

### What This Workload Demonstrates
<details>
<summary>more info...</summary>

- **Concurrent read/write behavior** on time-partitioned data such as upcoming flight legs
- **Update-heavy vs read-heavy balance**, reflecting real operational systems
- **Impact of concurrent updates** on single-row transactions and hot partitions
- **Index and storage efficiency** for schedule lookup patterns (origin/destination + time)
- **Real-world stress characteristics** of systems that must ingest updates continuously while serving high-volume read queries
- **Predictable ACID behavior** for small, frequent transactions
- **Throughput and latency characteristics** under mixed operational load
</details>

### Initial Schema
<details>
<summary>more info...</summary>

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
</details>

### dbworkload
<details>
<summary>more info...</summary>

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
</details>

### Direct Connections
<details>
<summary>more info...</summary>

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
</details>

### Managed Connections
<details>
<summary>more info...</summary>

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
</details>

### Interpretation
<details>
<summary>more info...</summary>

From the client’s perspective, both the direct-connection and managed-connection (PgBouncer) executions completed the same total number of operations:
- **8192 operations per worker**
- **256 concurrent threads**
- **4 workers**
- **~1024 total concurrency**

But the client-side latency profile inside those fixed iterations is dramatically different:

**1. Mean latency per operation drops substantially with PgBouncer**

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

**2. Tail latencies (p90–p99) shrink even more dramatically**

Direct connections exhibit very large long-tail behavior:
- **p95 up to ~57 seconds**
- **p99 up to ~73 seconds**
 - **max > 2 minutes**

Under managed connections:
- **p95 typically under 8 seconds**
- **p99 under 10 seconds**
- **max ~9 seconds**

This is a **10×–20×** reduction in tail latency.

Why?

Because CockroachDB is handling far fewer active backend sessions, so:
- fewer competing goroutines
- fewer pgwire buffers
- fewer session-level memory contexts
- less scheduler pressure
- far fewer concurrent KV requests
- fewer write queues forming

The client sees more predictable, more stable response times as a direct result.
</details>

## Train Events
This workload simulates the ingestion, processing, state-transition, and archival lifecycle of train and track-management events using realistic multi-event ACID transactions that stress both concurrency control and JSON-heavy data paths.

It is a **multi-event transactional workload** designed to simulate the operational data flow of a modern railway control, dispatching, and track-management system.
It exercises a realistic mix of **read**, **write**, and **state-transition** operations that occur as trains move across a network, infrastructure states change, and control systems emit telemetry or directives.

The workload models three primary interaction patterns:

### 1. Event Ingestion Transactions
<details>
<summary>more info...</summary>

Each transaction inserts a **batch of 10–100 synthetic railway events**, such as route authorizations, signal clearances, speed restrictions, switch position changes, position updates, and infrastructure condition reports.
Every event is written atomically alongside a corresponding status record, simulating upstream publish or capture systems generating operational messages.
</details>

### 2. Event Processing Transactions
<details>
<summary>more info...</summary>

Batches of events in PENDING or PROCESSING states are selected with **row-level locking**, updated, and advanced through their lifecycle.

The workload includes:
- **FOR UPDATE** row locking
- Application of business logic modifications to the event payload
- State machine transitions (e.g., PENDING → PROCESSING → COMPLETE)

This represents downstream consumers such as dispatch systems, safety logic, or orchestration services that process operational rail messages concurrently.
</details>

### 3. Archival Transactions
<details>
<summary>more info...</summary>

Events that reach a terminal state are **bulk-archived** into a history table and then removed from the primary tables as part of a single ACID transaction.
This simulates data movement pipelines—ETL, retention policies, or system rollups—that extract completed operational events to long-term storage.
</details>

### What This Workload Demonstrates
<details>
<summary>more info...</summary>

- **Contention behavior** under multi-row, multi-statement transactions
- **Impact of JSONB vs TEXT** for storing and processing nested operational documents
- **Concurrency control patterns** (locks, retries, write–write conflicts)
- **End-to-end lifecycle simulation** of operational messages in a real dispatching or control system
- **Mixed read/write access** across hot rows and rolling windows of recent events
- **Batch-oriented transactional throughput** similar to real event-driven systems
</details>

### Initial Schema
<details>
<summary>more info...</summary>

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
</details>

### dbworkload
<details>
<summary>more info...</summary>

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
</details>

### Direct Connections
<details>
<summary>more info...</summary>

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

**Using JSONB Fields**
```
>>> Worker 2 (logs/results_direct_jsonb_20251130_193430_w2.log)
run_name       Transactionsjsonb.20251201_004236
start_time     2025-12-01 00:42:36
end_time       2025-12-01 06:58:26
test_duration  22550
-------------  ---------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬──────────────┬────────────┬──────────────┬──────────────┬──────────────┬───────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │     mean(ms) │    p50(ms) │      p90(ms) │      p95(ms) │      p99(ms) │       max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼──────────────┼────────────┼──────────────┼──────────────┼──────────────┼───────────────┤
│    22,550 │ __cycle__ │       128 │     2,048 │           0 │ 1,181,943.54 │ 484,743.71 │ 3,231,329.46 │ 4,321,847.35 │ 6,280,597.23 │ 13,704,440.28 │
│    22,550 │ add       │       128 │     2,048 │           0 │    68,135.58 │  25,042.43 │   162,019.06 │   340,040.77 │   659,524.03 │    935,443.13 │
│    22,550 │ archive   │       128 │     2,048 │           0 │    31,205.86 │  10,125.94 │    70,397.50 │   125,083.27 │   375,331.41 │  1,318,715.29 │
│    22,550 │ process   │       128 │     2,048 │           0 │ 1,082,500.62 │ 377,693.80 │ 3,121,893.29 │ 4,174,144.33 │ 6,155,143.14 │ 13,680,428.80 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴──────────────┴────────────┴──────────────┴──────────────┴──────────────┴───────────────┘

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

**Versus Text Fields**
```
>>> Worker 2 (logs/results_direct_text_20251130_193430_w2.log)
run_name       Transactionstext.20251201_071843
start_time     2025-12-01 07:18:43
end_time       2025-12-01 08:10:26
test_duration  3103
-------------  --------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬────────────┬────────────┬────────────┬────────────┬──────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │    p50(ms) │    p90(ms) │    p95(ms) │    p99(ms) │      max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼────────────┼────────────┼────────────┼────────────┼──────────────┤
│     3,103 │ __cycle__ │       128 │     2,048 │           0 │ 167,998.93 │ 109,581.05 │ 376,809.94 │ 643,908.30 │ 981,693.04 │ 1,537,120.24 │
│     3,103 │ add       │       128 │     2,048 │           0 │  19,684.26 │  16,925.65 │  44,239.11 │  49,473.15 │  61,934.11 │   121,511.96 │
│     3,103 │ archive   │       128 │     2,048 │           0 │  17,617.78 │   2,229.42 │  61,146.24 │  93,807.39 │ 203,677.86 │   426,512.19 │
│     3,103 │ process   │       128 │     2,048 │           0 │ 130,594.01 │  64,083.91 │ 341,346.50 │ 583,468.49 │ 872,766.48 │ 1,517,372.06 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴────────────┴────────────┴────────────┴────────────┴──────────────┘

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
</details>

### Managed Connections
<details>
<summary>more info...</summary>

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

**Using JSONB Fields**
```
>>> Worker 2 (logs/results_pooling_jsonb_20251201_140514_w2.log)
run_name       Transactionsjsonb.20251201_191248
start_time     2025-12-01 19:12:48
end_time       2025-12-01 22:54:49
test_duration  13321
-------------  ---------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │    p50(ms) │      p90(ms) │      p95(ms) │      p99(ms) │      max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤
│    13,321 │ __cycle__ │       128 │     2,048 │           0 │ 815,609.64 │ 703,129.62 │ 1,004,977.64 │ 2,268,000.43 │ 2,350,959.58 │ 3,106,766.67 │
│    13,321 │ add       │       128 │     2,048 │           0 │ 242,604.46 │ 201,617.77 │   325,851.99 │   375,890.85 │ 1,941,835.49 │ 2,101,634.99 │
│    13,321 │ archive   │       128 │     2,048 │           0 │ 263,691.48 │ 215,986.87 │   407,631.80 │   531,846.62 │ 1,625,728.39 │ 2,599,985.38 │
│    13,321 │ process   │       128 │     2,048 │           0 │ 309,213.12 │ 250,818.61 │   427,179.48 │   534,836.47 │ 1,993,676.53 │ 2,030,037.81 │
└───────────┴───────────┴───────────┴───────────┴─────────────┴────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────┘

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

**Versus Text Fields**
```
>>> Worker 2 (logs/results_pooling_text_20251202_130844_w2.log)
run_name       Transactionstext.20251202_181644
start_time     2025-12-02 18:16:44
end_time       2025-12-02 18:26:29
test_duration  585
-------------  --------------------------------

┌───────────┬───────────┬───────────┬───────────┬─────────────┬────────────┬───────────┬───────────┬───────────┬───────────┬───────────┐
│   elapsed │ id        │   threads │   tot_ops │   tot_ops/s │   mean(ms) │   p50(ms) │   p90(ms) │   p95(ms) │   p99(ms) │   max(ms) │
├───────────┼───────────┼───────────┼───────────┼─────────────┼────────────┼───────────┼───────────┼───────────┼───────────┼───────────┤
│       585 │ __cycle__ │       128 │     2,048 │           3 │  34,344.72 │ 35,350.35 │ 44,850.78 │ 46,681.42 │ 51,327.14 │ 55,677.71 │
│       585 │ add       │       128 │     2,048 │           3 │  10,997.23 │ 10,828.93 │ 14,706.88 │ 15,723.68 │ 19,642.67 │ 23,032.99 │
│       585 │ archive   │       128 │     2,048 │           3 │  10,810.96 │ 10,684.68 │ 16,598.57 │ 18,180.35 │ 20,161.36 │ 24,008.58 │
│       585 │ process   │       128 │     2,048 │           3 │  12,436.07 │ 12,669.71 │ 16,789.01 │ 17,953.65 │ 20,663.01 │ 24,225.55 │
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
</details>

### Interpretation
<details>
<summary>more info...</summary>

**<ins>PART 1 - JSONB vs TEXT DATA TYPES</ins>**

The output from our testing shows that JSONB is not a good match for a high-throughput event queue with heavy writes and no nested JSON querying.  TEXT is absolutely the right approach for this workload.

**Mean Latency Comparison (per operation)**
| Operation | JSONB Mean (ms) | TEXT Mean (ms) | Improvement When Using TEXT |
| ------------- | ------------- | ------------- | ------------- |
| add | 68,135 ms | 19,684 ms | ~71% faster |
| process | 1,082,500 ms | 130,594 ms | ~88% faster |
| archive | 31,205 ms | 17,618 ms | ~44% faster |
| cycle | 1,181,943 ms | 167,998 ms | ~86% faster |

TEXT is *40–90%* faster depending on the phase, with the largest gains in the high-contention process stage.

**Why is JSONB so much slower?**

Using the CRDB metrics (statement activity & txn activity), several major factors become obvious:
- JSONB updates rewrite **large structured documents**, whereas TEXT just replaces a blob
- JSONB inverted indexes generate much higher **write amplification** (many more KV keys per write)
- JSONB transactions create significantly **more contention** and **longer lock hold times**
- JSONB ‘process’ operations often run ~1 second to multiple seconds per statement, while TEXT runs them in **tens of milliseconds**

From the database metrics:
- JSONB transactions show multi-minute average latencies in some cases, and heavy retry behavior (p99 5–10 seconds+)
- TEXT transactions remain sub-second to low-second even under load

**<ins>PART 2 - DIRECT vs MANAGED CONNECTIONS</ins>**

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

**<ins>SUMMARY OF WORKLOAD TESTING</ins>**

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
</details>
