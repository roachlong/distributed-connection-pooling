# distributed-connection-pooling

1. [Overview](#overview)
1. [Solution Architecture](#solution-architecture)
1. [Test Results](#test-results)
1. [CockroachDB](#cockroachdb)
1. [PgBouncer](#pgbouncer)
1. [High Availability](#high-availability)
1. [Reference Architecture](#reference-architecture)
1. [Event Logs Workload](./workloads/event-logs/README.md)
1. [Flight Schedules Workload](./workloads/flight-schedules/README.md)
1. [Train Events Workload](./workloads/train-events/README.md)

## Overview

This repository was created to demonstrate a **fault-tolerant, highly available connection pooling solution for CockroachDB** that is **managed externally from application stacks**.

Modern distributed databases like CockroachDB can handle large volumes of concurrent connections, but many applications and frameworks still open and close database sessions inefficiently or hold idle connections longer than necessary. This creates unnecessary load on the database and limits scalability.

By **centralizing and externalizing connection pooling**, we decouple connection lifecycle management from the application tier — allowing each service to use lightweight, short-lived database sessions while still maintaining consistent access to a shared pool of open connections.

### Why External Connection Pooling?
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
When many microservices each maintain their own pools, the database sees a “fan-out” of sessions. Spiky traffic and idle-but-open sessions waste resources and can starve active work.

[<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/connection-swarm.svg">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/connection-swarm.svg)

**Symptoms**
- **Connection swarm**: N services × M pool size ⇒ **N×M sessions** on CRDB.
- **Starvation / head-of-line blocking**: Busy services grab connections while others sit idle; spikes cause thrash.
- **High session churn & metadata overhead**: DB spends cycles managing sessions instead of executing queries.
- **Operational sprawl**: Auth, timeouts, and limits duplicated across every app.

### Architecture (Solution): Distributed Connection Pooling with HA
Centralize connection lifecycle management behind a **stable VIP**. HAProxy handles frontend health/routing; PgBouncer multiplexes many client sessions onto a compact backend pool; Pacemaker/Corosync orchestrates failover and fencing.

[<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/distributed-connection-pooling.svg">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/distributed-connection-pooling.svg)

**What this fixes**
- **Right-sized backend sessions**: Thousands of client connections map to **dozens** of CRDB sessions.
- **Fewer idle drains**: PgBouncer reuses backends across sessions/transactions; HAProxy evens out spikes.
- **Fast, clean failover**: Pacemaker moves the VIP + services; fencing prevents split-brain.
- **Centralized control**: One place to tune auth, timeouts, pool sizes, and limits.

### Key Attributes of This Solution
- **Highly Available**: Automatic failover of the PgBouncer + HAProxy stack through Pacemaker-managed floating IPs.

- **Fault Tolerant**: Node failures are isolated via STONITH fencing, ensuring data safety and service continuity.

- **Externally Managed**: Pooling and routing occur outside the application tier, simplifying configuration and improving maintainability.

- **Scalable Design**: Easily extended from a laptop demo to multi-VM or multi-region clusters with minimal changes.

- **Configurable Topology**: Supports both session and transaction pooling modes, adjustable via PgBouncer configuration.

- **Demonstrable Locally**: The full HA setup (including Corosync, Pacemaker, HAProxy, and PgBouncer) runs in containers for experimentation and reproducibility.

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
**Direct Connections**
[<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-activity.png">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/direct-sql-activity.png)

**Managed Connections**
[<img src="https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-activity.png">](https://raw.githubusercontent.com/roachlong/distributed-connection-pooling/refs/heads/main/images/pooling-sql-activity.png)

### Side-by-Side Metrics
Metrics collected from the database during both executions reveal significant differences in **internal transaction management and resource utilization**. The following charts present the two runs side by side.

<details>
<summary>expand to see metrics...</summary>

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

## CockroachDB

**CockroachDB** is a **distributed SQL database** built for **global scale, strong consistency, and high resilience**. It’s wire-compatible with PostgreSQL, which means it supports the same SQL syntax, drivers, and tools — including PgBouncer — while providing automatic replication, fault tolerance, and horizontal scalability.

Unlike traditional databases that rely on a single primary node, CockroachDB distributes data automatically across multiple nodes. Each node can serve reads and writes, and the system ensures **ACID transactions** even in the presence of node or network failures. This makes it ideal for applications that require continuous availability and strong data integrity.

In this demo, CockroachDB serves as the **backend database** behind PgBouncer. While the example uses a single-node secure cluster for simplicity, the same principles apply to multi-node and multi-region deployments. The focus here is on the **connection management layer** — showing how PgBouncer can efficiently manage database sessions and reduce load on CockroachDB in high-concurrency environments.

### Why CockroachDB Benefits from Connection Pooling
Each connection to CockroachDB represents an active **SQL session** with its own memory context, transaction state, and session-level metadata. In busy application environments — particularly those with many microservices or short-lived requests — rapidly opening and closing connections can create overhead that limits scalability and increases latency.

Using **PgBouncer** as an intermediary allows applications to reuse a smaller set of persistent backend sessions while still handling thousands of concurrent client requests. This reduces pressure on CockroachDB’s session management layer, minimizes transaction contention, and ensures that the database remains focused on executing queries rather than maintaining idle connections.

Together, CockroachDB and PgBouncer form a robust foundation for **distributed, fault-tolerant connection management**, where scaling the application tier doesn’t compromise database performance or stability.

### CockroachDB Setup
We'll start by configuring a local secure database database cluster that will provide the backend for testing connections through pgbouncer.  We'll use a secure cluster so we can insert connection management between the application components and our database using PgBouncer.  This demo is not meant to demonstrate the reliability and throughput capabilities of CockroachDB.  It will primarily focus on the performance of connection management to the backend.  We can run cockroach as a single-node for simple use cases, or use docker to simulate a multi-region scenario.

**<ins>CERTS</ins>**
1) Create a directory to hold our self-signed certificate ```mkdir -p certs my-safe-directory```
1) Then run the cockroach commands to generate the certs.
```
cockroach cert create-ca --certs-dir=certs --ca-key=my-safe-directory/ca.key
cockroach cert create-node localhost us-east us-central us-west 127.0.0.1 $(hostname -f) --certs-dir=certs --ca-key=my-safe-directory/ca.key
cockroach cert create-client root --certs-dir=certs --ca-key=my-safe-directory/ca.key
chmod 600 ./certs/node.key
chmod 600 ./certs/client.root.key
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

**<ins>CLUSTER</ins>**

<details>
<summary>expand for single-node...</summary>

Then check your cockroach version and start your single node instance with the new certs.
```
cockroach --version
cockroach start-single-node --certs-dir=./certs --store=./data --advertise-addr=localhost:26257 --background
```
</details>

<br/>

<details>
<summary>expand for multi-region...</summary>

**Note**: if you have enough system resources you can try running cockroach locally to simulate multi-region using the docker-compose script.  But make sure you start colima with ```--network-address``` and include extra resource capacity
```
colima start --network-address --memory 8 --cpu 4 --disk 100
export CRDB_VERSION=$(cockroach --version | grep "Build Tag" | awk '{print $3}')
cd cockroachdb
docker-compose up --detach
cd ..
```

Next we'll need to configure our multi-region cluster
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb?sslmode=verify-full" -e """
ALTER DATABASE defaultdb SET PRIMARY REGION 'us-east-1';
ALTER DATABASE defaultdb ADD REGION 'us-central-1';
ALTER DATABASE defaultdb ADD REGION 'us-west-2';
ALTER DATABASE defaultdb SURVIVE REGION FAILURE;
"""
```
</details>

<br/>**<ins>USERS</ins>**

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

<br/>**<ins>KAFKA</ins>**
We'll setup a sink with Kafka in case we want to test workloads that require change data capture.  We'll deploy in dcoker but we may also want to use the client tools to set things up.  On Mac we can install them with ```brew install kafka``` and on Windows we can download and extract the tar file from [here](https://kafka.apache.org/downloads), then add the location of the Kafka .bat files (i.e. C:\Users\myname\kafka\bin\Windows) to your Windows Path environment variable.

There's a docker compose file in the kafka folder that we can use to launch our local instance of kafka, which will configure a single replica with 10 partitions.
```
cd kafka
docker-compose up --detach
cd ..
```
Once launched you can confirm the containers are up and running with ```docker ps```.  Then we can create our topics and you can investigate your Kafka cluster at h

To create change feeds in cockroachdb we'll need to provide an organization with a temporary license.  We'll store this information as variables in the terminal shell window.  On Mac variables are assigned like ```my_var="example"``` and on Windows we proceed the variable assignment with a $ symbol ```$my_var="example"```.
```
organization="Workshop"
license="willBeProvided"
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb?sslmode=verify-full" -e """
SET CLUSTER SETTING cluster.organization = '$organization';
SET CLUSTER SETTING enterprise.license = '$license';
SET CLUSTER SETTING kv.rangefeed.enabled = true;
"""
```

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
Before we get started we'll need to increase the capacity of our docker network to handle 2048 connections

<details>
<summary>more info...</summary>


First, we'll start colima with less resources to run the HA services.
```
colima stop
colima start --network-address --memory 4 --cpu 2 --disk 50
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
docker stop $(docker ps -aq --filter "name=^pgbouncer") $(docker ps -aq --filter "name=^ha-node") vip-proxy
docker rm $(docker ps -aq --filter "name=^pgbouncer") $(docker ps -aq --filter "name=^ha-node") vip-proxy
```
</details>

### PgBouncer Setup
Next we'll build our pgbouncer docker image and spin up two pgbouncer instances for a single node, or per region

<details>
<summary>expand for single-node...</summary>

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

<br/>

<details>
<summary>expand for multi-region...</summary>

First we'll need to create a client certificate for our multi-region cluster and a server-side certificate for pgbouncer
```
cockroach cert create-client pgb --certs-dir=./certs --ca-key=./my-safe-directory/ca.key
chmod 600 ./certs/client.pgb.key

# generate the config file used for CSR and signing
cat > "./certs/server.pgbouncer.cnf" <<EOF
[ req ]
default_bits        = 4096
prompt              = no
default_md          = sha256
distinguished_name  = req_distinguished_name
req_extensions      = v3_req

[ req_distinguished_name ]
CN = pgbouncer

[ v3_req ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
DNS.2 = pgbouncer-us-east-1
DNS.3 = pgbouncer-us-east-2
DNS.4 = pgbouncer-us-central-1
DNS.5 = pgbouncer-us-central-2
DNS.6 = pgbouncer-us-west-1
DNS.7 = pgbouncer-us-west-2
IP.1  = 127.0.0.1
IP.2  = 172.18.0.251
IP.3  = 172.18.0.252
IP.4  = 172.18.0.253
EOF

# generate a private key for PgBouncer (server key)
openssl genrsa -out ./certs/server.pgbouncer.key 4096
chmod 600 ./certs/server.pgbouncer.key

# create a CSR using that key + config
openssl req \
  -new \
  -key ./certs/server.pgbouncer.key \
  -out ./certs/server.pgbouncer.csr \
  -config ./certs/server.pgbouncer.cnf

# sign the CSR with existing cockroach CA
openssl x509 \
  -req \
  -in ./certs/server.pgbouncer.csr \
  -CA ./certs/ca.crt \
  -CAkey ./my-safe-directory/ca.key \
  -CAcreateserial \
  -out ./certs/server.pgbouncer.crt \
  -days 365 \
  -sha256 \
  -extensions v3_req \
  -extfile ./certs/server.pgbouncer.cnf

# verify the SANs look correct
openssl x509 -in ./certs/server.pgbouncer.crt -noout -text | grep -A1 "Subject Alternative Name"
```

And then build the image and deploy the instances
```
docker network create dcp-net

docker build -t pgbouncer --build-arg PGBOUNCER_VERSION=1.17.0 pgbouncer

REGIONS=("us-east" "us-west" "us-central")
NODES_PER_REGION=2

for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 $NODES_PER_REGION); do
    
    NAME="pgbouncer-${region}-${idx}"      # e.g., pgbouncer-us-east-1
    echo "🚀 Starting ${NAME}, targeting ${region}"

    docker container run \
      --name "${NAME}" \
      --network dcp-net \
      --ulimit nofile=262144:262144 \
      -v ./certs:/etc/pgbouncer/certs \
      -d pgbouncer \
      --client-account pgb \
      --server-account pgb \
      --auth-mode cert \
      --num-connections 24 \
      --host-ip "${region}" \
      --host-port 26257 \
      --database defaultdb

  done
done
```

Or to restart all pgbouncer containers
```
docker restart $(docker ps -a --filter "name=^pgbouncer" --format "{{.Names}}")
```

Then to test the connection pool we can go inside the container
```
docker exec -it pgbouncer-us-east-1 /bin/bash
wget https://binaries.cockroachdb.com/cockroach-latest.linux-arm64.tgz
tar -xvzf cockroach-latest.linux-arm64.tgz
cp cockroach-*/cockroach /usr/local/bin/
cockroach version
cockroach sql --certs-dir /etc/pgbouncer/certs --url "postgresql://pgb@localhost:5432/defaultdb?sslmode=verify-full" -e "show databases;"
exit
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
**Corosync** and **Pacemaker** together form the **high-availability cluster stack** that keeps services like HAProxy and the VIP running on exactly one healthy node at a time.

- **Corosync** provides the **cluster communication layer** — it handles membership, heartbeats, and quorum. It ensures each node knows who’s alive, who’s failed, and when it’s safe to take over shared resources.

- **Pacemaker** runs on top of Corosync as the **cluster resource manager**. It decides where to start or stop each service (e.g., HAProxy, PgBouncer, or a virtual IP), monitors their health, and automatically performs **failover** if a node or service goes down.

In this demo, Corosync and Pacemaker coordinate between two HAProxy nodes. Only one node at a time “owns” the virtual IP and serves traffic. If that node fails, Pacemaker moves the VIP (and HAProxy) to the other node within seconds, ensuring uninterrupted client access.

Together they form the brains of the HA cluster — Corosync detects failure, Pacemaker makes recovery decisions, and fencing ensures safety.

### What is STONITH / Fencing?
**STONITH** stands for “**Shoot The Other Node In The Head**.” It’s Pacemaker’s fencing mechanism — the ultimate safeguard against **split-brain** conditions in a cluster.

When a node stops responding or loses quorum, Pacemaker doesn’t immediately assume it’s truly dead. To avoid two nodes simultaneously taking ownership of shared resources (like a VIP or database), the cluster first performs **fencing**: it forcibly isolates or powers off the suspect node so that it cannot corrupt data or conflict with the survivor.

Common fencing methods include:
- **IPMI / iDRAC / iLO** hardware power-off
- **Cloud API fencing** (AWS, Azure, GCP)
- **Shared-disk fencing (SBD)** for physical clusters
- **Fence agents** like fence_vmware, fence_apc, etc.

In this Docker-based demo, we use the lightweight fence_dummy agent — it doesn’t actually power off containers, but it lets us see how Pacemaker would trigger fencing in a real deployment.

Fencing guarantees that at any given time, only one node controls critical resources — the key to maintaining **data consistency** and **cluster integrity** in any high-availability design.

### HA Setup
<details>
<summary>expand for single-node...</summary>

<br/>
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

<br/>

<details>
<summary>expand for multi-region...</summary>

<br/>
<details>
<summary>1. Start by creating two containers per region using the host network so they can manipulate an IP on the host interface:</summary>

```
docker build -t ha-node ha-node

REGIONS=("us-east" "us-west" "us-central")
NODES_PER_REGION=2

for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 $NODES_PER_REGION); do

    NAME="ha-node-${region}-${idx}"      # e.g., ha-node-us-east-1
    echo "🚀 Starting ${NAME}, targeting ${region}"

    docker container run \
        --name "${NAME}" \
        --hostname "${NAME}" \
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
done
```

Or to restart all ha-node containers
```
docker restart $(docker ps -a --filter "name=^ha-node" --format "{{.Names}}")
```
</details>

<details>
<summary>2. And confirm that systemd is running inside each node</summary>

```
for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 $NODES_PER_REGION); do
    docker exec -it "ha-node-${region}-${idx}" bash -lc 'systemctl is-system-running --wait || true; hostname -f'
  done
done
```
</details>

<details>
<summary>3. Next enable pcsd and set the hacluster password on both nodes</summary>

```
for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 $NODES_PER_REGION); do
    docker exec -it "ha-node-${region}-${idx}" bash -lc '
    systemctl enable --now pcsd &&
    echo -e "secret\nsecret" | passwd hacluster
    '
  done
done
```
</details>

<details>
<summary>4. Get each HA node’s IP (on dcp-net) and ensure node name resolution</summary>

First create a map of the IPs for each node
```
declare -A HA_NODE_IP

for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"

    IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NODE")

    echo "$NODE → $IP"
    HA_NODE_IP["$region-$idx"]="$IP"
  done
done

echo "IP of us-east-2 = ${HA_NODE_IP["us-east-2"]}"
```

Then store the lines for /etc/hosts in each region
```
declare -A REGION_HOST_LINES

for region in "${REGIONS[@]}"; do
  lines=""
  for idx in $(seq 1 "$NODES_PER_REGION"); do
    key="${region}-${idx}"
    node="ha-node-${region}-${idx}"
    ip="${HA_NODE_IP[$key]}"
    lines+="${ip} ${node}\n"
  done
  REGION_HOST_LINES["$region"]="$lines"
done

echo "etc hosts for us-east = ${REGION_HOST_LINES["us-east"]}"
```

And finally update the nodes in each region with their sibling hosts
```
for region in "${REGIONS[@]}"; do
  host_lines="${REGION_HOST_LINES[$region]}"

  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"

    echo "Updating /etc/hosts inside ${NODE} for region ${region}..."

    docker exec -i "${NODE}" bash -lc "
      set -e
      cp /etc/hosts /etc/hosts.bak

      # Remove existing entries for THIS region's ha-nodes
      awk '!/\bha-node-${region}-/' /etc/hosts > /tmp/hosts

      # Prepend fresh mappings for this region's nodes
      printf '${host_lines}' | cat - /tmp/hosts > /etc/hosts

      echo 'Resolution for regional nodes now:'
      $(for i in $(seq 1 "$NODES_PER_REGION"); do
          echo "getent hosts ha-node-${region}-${i} || true"
        done)

      echo 'HEAD of /etc/hosts:'
      sed -n '1,10p' /etc/hosts
    "
  done
done

docker exec -it ha-node-us-east-1 bash -lc 'hostname -f; getent hosts ha-node-us-east-2'
```
</details>

<details>
<summary>5. Configure Corosync with UDPU instead of multi-cast</summary>

**Why UDPU?**
Docker/Colima often block multicast; UDPU (unicast) avoids that and stabilizes the Corosync ring.

First generate and distribute an authkey for each region:
```
for region in "${REGIONS[@]}"; do
  SEED_NODE="ha-node-${region}-1"

  echo "Generating authkey on seed node ${SEED_NODE} for region ${region}..."
  docker exec -it "${SEED_NODE}" bash -lc '
    corosync-keygen -l
    chmod 400 /etc/corosync/authkey
  '

  KEY64=$(docker exec "${SEED_NODE}" bash -lc "base64 -w0 /etc/corosync/authkey")

  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"
    if [[ "${NODE}" == "${SEED_NODE}" ]]; then
      continue
    fi

    echo "Copying authkey for region ${region} to ${NODE}..."
    docker exec -i "${NODE}" bash -lc "
      umask 177
      echo '${KEY64}' | base64 -d > /etc/corosync/authkey
      chmod 400 /etc/corosync/authkey
    "
  done
done
```

Then write the following config on both nodes for two-node quorum tuning in each region:
```
for region in "${REGIONS[@]}"; do
  # For a 2-node cluster per region
  IP1="${HA_NODE_IP["${region}-1"]}"
  IP2="${HA_NODE_IP["${region}-2"]}"

  NODE1="ha-node-${region}-1"
  NODE2="ha-node-${region}-2"

  echo "Configuring corosync for region ${region}:"
  echo "  ${NODE1} → ${IP1}"
  echo "  ${NODE2} → ${IP2}"

  CONF=$(cat <<EOF
totem {
    version: 2
    cluster_name: ha-cluster-${region}
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
        name: ${NODE1}
        ring0_addr: ${IP1}
        link {
            addr: ${IP1}
        }
    }
    node {
        nodeid: 2
        name: ${NODE2}
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

  # Copy the same config to both nodes in this region
  for NODE in "${NODE1}" "${NODE2}"; do
    echo "  → writing /etc/corosync/corosync.conf on ${NODE}"
    docker exec -i "${NODE}" bash -lc 'cat > /etc/corosync/corosync.conf' <<<"$CONF"
  done

  # Validate config on each node
  for NODE in "${NODE1}" "${NODE2}"; do
    echo "  → validating corosync config on ${NODE}"
    docker exec -it "${NODE}" bash -lc 'corosync -f -t && echo "Config OK on $(hostname -f)"'
  done

done
```

Then start the cluster stack in each region:
```
for region in "${REGIONS[@]}"; do
  echo "=== Starting Corosync/Pacemaker in region ${region} ==="

  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"

    echo "Configuring corosync service override on ${NODE}..."

    docker exec -it "$NODE" bash -lc '
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

  echo "Enabling corosync + pacemaker on region ${region} nodes..."
  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"

    docker exec -it "$NODE" bash -lc '
      systemctl enable --now corosync pacemaker
    '
  done
done
```

And check the cluster status per region:
```
for region in "${REGIONS[@]}"; do
  echo "=== Corosync status for region ${region} ==="

  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"
    echo "--- ${NODE} ---"
    docker exec -it "$NODE" bash -lc '
      echo "# corosync-cfgtool -s"
      corosync-cfgtool -s || echo "corosync-cfgtool failed"

      echo
      echo "# tail corosync.log (last 50 lines)"
      tail -n 50 /var/log/corosync/corosync.log || true

      echo
      echo "# pcs status (if pcs is installed/configured)"
      pcs status || echo "pcs not yet configured or not installed"
    '
  done
done
```
</details>

<details>
<summary>6. Bootstrap pacemaker properties but temporarily relax fencing/quorum across the regions</summary>

```
for region in "${REGIONS[@]}"; do
  SEED_NODE="ha-node-${region}-1"

  echo "=== Setting Pacemaker properties in region ${region} (via ${SEED_NODE}) ==="

  docker exec -it "${SEED_NODE}" bash -lc '
    # Disable STONITH (fencing) for now
    pcs property set stonith-enabled=false

    # Ignore quorum loss (OK for 2-node lab/demo, not for prod)
    pcs property set no-quorum-policy=ignore

    echo
    echo "Cluster properties:"
    pcs property show

    echo
    echo "Cluster status:"
    pcs status
  '
done
```
Should report both nodes Online in each region: i.e. [ ha-node-us-east-1 ha-node-us-east-2 ].
</details>

<details>
<summary>7. Create the VIP inside the Docker network for each region</summary>

We picked 172.18.0.251|2|3/24; NIC is eth0 inside these containers:
```
declare -A REGION_VIP
REGION_VIP["us-east"]="172.18.0.251"
REGION_VIP["us-central"]="172.18.0.252"
REGION_VIP["us-west"]="172.18.0.253"

for region in "${REGIONS[@]}"; do
  SEED_NODE="ha-node-${region}-1"
  VIP="${REGION_VIP[$region]}"

  echo "=== Creating VIP for region ${region}: ${VIP} on ${SEED_NODE} ==="

  docker exec -it "${SEED_NODE}" bash -lc "
    pcs resource create vip-${region} ocf:heartbeat:IPaddr2 \
      ip=${VIP} cidr_netmask=24 nic=eth0 \
      op monitor interval=30s

    echo
    echo 'Resources in region ${region}:'
    pcs status resources
  "
done
```
</details>

<details>
<summary>8. Configure HAProxy and colocate it with the VIP</summary>

Push a simple pgsql TCP LB config to both nodes:
```
for region in "${REGIONS[@]}"; do
  echo "=== Configuring HAProxy for region ${region} ==="

  # HAProxy sees the PgBouncer containers by name on the dcp-net
  PGB1="pgbouncer-${region}-1"
  PGB2="pgbouncer-${region}-2"

  # Build a region-specific haproxy.cfg in /tmp
  CFG_FILE="/tmp/haproxy-${region}.cfg"

  cat > "${CFG_FILE}" <<CFG
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
    # regional PgBouncer endpoints
    server pgb1 ${PGB1}:5432 check
    server pgb2 ${PGB2}:5432 check
CFG

  # Copy this config into both HA nodes in the region
  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"
    echo "  → pushing haproxy.cfg to ${NODE}"
    docker cp "${CFG_FILE}" "${NODE}:/etc/haproxy/haproxy.cfg"
  done

  # Enable and start HAProxy on both nodes
  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"
    echo "  → enabling and starting haproxy on ${NODE}"
    docker exec -it "${NODE}" bash -lc 'systemctl enable --now haproxy && systemctl is-active haproxy'
  done

done
```

Add HAProxy as a Pacemaker resource and colocate with VIP in each region:
```
for region in "${REGIONS[@]}"; do
  SEED_NODE="ha-node-${region}-1"

  echo "=== Creating HAProxy resource and constraints for region ${region} ==="

  docker exec -it "${SEED_NODE}" bash -lc "
    # Create HAProxy as a systemd resource
    pcs resource create haproxy-${region} systemd:haproxy op monitor interval=10s

    # Ensure VIP starts before HAProxy
    pcs constraint order start vip-${region} then haproxy-${region}

    # Ensure HAProxy always runs on the node that owns the VIP
    pcs constraint colocation add haproxy-${region} with vip-${region} INFINITY

    echo
    echo 'Cluster resources for region ${region}:'
    pcs status resources
  "
done
```
</details>

<details>
<summary>9. Test from a client container on the same network</summary>

Your host can’t reach the VIP so we'll test from another container inside dcp-net.
```
for region in "${REGIONS[@]}"; do
  VIP="${REGION_VIP[$region]}"

  echo "=== Testing region ${region} via VIP ${VIP} ==="

  docker run --rm -it \
    --network dcp-net \
    -v ./certs:/etc/pgbouncer/certs \
    alpine sh -c "
      apk add --no-cache postgresql15-client curl >/dev/null && \
      echo 'Stats page:' && curl -s http://${VIP}:8404/stats | head -n 3 || true && \
      echo && echo 'psql via VIP with TLS + client cert:' && \
      psql \"postgresql://pgb@${VIP}:5432/defaultdb?sslmode=require&sslrootcert=/etc/pgbouncer/certs/ca.crt&sslcert=/etc/pgbouncer/certs/client.pgb.crt&sslkey=/etc/pgbouncer/certs/client.pgb.key\" -c 'show databases;' \
    "
done
```
</details>

<details>
<summary>10. Prove failover for the us-east region</summary>
Move resources to node2
```
docker exec -it ha-node-us-east-1 bash -lc 'pcs resource move vip-us-east ha-node-us-east-2 && sleep 2 && pcs status'
```

Check which node holds the VIP
```
VIP="${REGION_VIP[us-east]}"
docker exec -it ha-node-us-east-1 bash -lc "ip addr show eth0 | grep ${VIP} || true"
docker exec -it ha-node-us-east-2 bash -lc "ip addr show eth0 | grep ${VIP} || true"
```

Hit the VIP again (should still work)
```
docker run --rm -it \
  --network dcp-net \
  -v ./certs:/etc/pgbouncer/certs \
  alpine sh -c "
    apk add --no-cache postgresql15-client curl >/dev/null && \
    psql \"postgresql://pgb@${VIP}:5432/defaultdb?sslmode=require&sslrootcert=/etc/pgbouncer/certs/ca.crt&sslcert=/etc/pgbouncer/certs/client.pgb.crt&sslkey=/etc/pgbouncer/certs/client.pgb.key\" -c 'show databases;' \
  "
```
</details>

<details>
<summary>11. Enable dummy fencing for demonstration in each region.</summary>

```
for region in "${REGIONS[@]}"; do
  SEED_NODE="ha-node-${region}-1"
  HOST1="ha-node-${region}-1"
  HOST2="ha-node-${region}-2"

  echo "=== Configuring dummy fencing in region ${region} via ${SEED_NODE} ==="

  docker exec -it "${SEED_NODE}" bash -lc "
    # Turn STONITH back on (cluster-wide)
    pcs property set stonith-enabled=true

    # Create a region-specific dummy fence device
    pcs stonith create fence-demo-${region} fence_dummy pcmk_host_list='${HOST1} ${HOST2}'

    echo
    echo 'STONITH devices in region ${region}:'
    pcs stonith show

    echo
    echo 'Cluster status:'
    pcs status
  "
done
```
In real VMs/hardware, replace fence_dummy with IPMI/libvirt/cloud agents.
</details>

<details>
<summary>12. Some commands to verify status of HA cluster</summary>

```
docker exec -it ha-node-us-east-1 bash -lc "pcs status"
docker exec -it ha-node-us-east-1 bash -lc "corosync-cfgtool -s"
docker exec -it ha-node-us-east-1 bash -lc "tail -n 100 /var/log/corosync/corosync.log"
```
</details>
</details>


## Reference Architecture
### WIP
We can setup an actual multi-region cluster in the cloud of your choice.  I'm going to use AWS with terraform and then simulate the distributed connection pool locally.  I'll start by setting up my AWS crednetials with my SSO profile and verify with a simple aws cli command.
```
# first i needed to update my aws cli version
curl -k "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg ./AWSCLIV2.pkg -target /
rm AWSCLIV2.pkg
echo "alias aws='/usr/local/bin/aws'" >> ~/.bashrc
source ~/.bashrc
which aws
aws --version

# then try to login and verify access
aws sso login --profile crl-revenue
aws ec2 describe-instance-types --instance-types m6i.2xlarge

# and create an ssh key pair to connect with our aws instances
ssh-keygen -b 2048 -f dev
mv ./dev ./my-safe-directory/. && mv ./dev.pub ./my-safe-directory/.
aws ec2 import-key-pair \
  --key-name dev \
  --public-key-material fileb://./my-safe-directory/dev.pub \
  --region us-east-1
aws ec2 import-key-pair \
  --key-name dev \
  --public-key-material fileb://./my-safe-directory/dev.pub \
  --region us-east-2
aws ec2 import-key-pair \
  --key-name dev \
  --public-key-material fileb://./my-safe-directory/dev.pub \
  --region us-west-1
aws ec2 import-key-pair \
  --key-name dev \
  --public-key-material fileb://./my-safe-directory/dev.pub \
  --region us-west-2
```

In order to test the reference architecture from our work stations we'll need to enable a public zone in AWS that will allow our client to connect with the cluster.
```
aws route53 create-hosted-zone \
  --name dcp-test.crdb.com \
  --caller-reference "$(date +%s)" \
  --hosted-zone-config Comment="Public zone for DCP / Cockroach access",PrivateZone=false

# then create a subdomain for dcp-test at your domain registrar
# and lookup the AWS nameservers to add NS records for the subdomain
aws route53 get-hosted-zone --id Z09942323KHF5XIP6R8IR

# once done the following should return matching NS records
dig NS dcp-test.crdb.com
```

If the credentials for your AWS account work and the hosted zone is available then you should be able to leverage the startup scripts with terraform to setup our reference architecture for testing.  We can use a tfvars file to configure our cluster, i.e.
```
# to find your public ip for the ssh ip range you can use
dig +short myip.opendns.com @resolver1.opendns.com

# then setup the values for your tfvars configuration
cat <<'EOF' > ./terraform/aws/crdb-dcp-test.tfvars
project_name = "crdb-dcp-test"
project_tags = {
    Project = "jsonb-vs-text"
}
dns_zone = "dcp-test.crdb.com"
public_zone_id = "Z09942323KHF5XIP6R8IR"
enabled_regions = ["us-east-2", "us-west-1", "us-west-2]
vpc_cidrs = {
    us-east-1 = "10.10.0.0/16"
    us-east-2 = "10.20.0.0/16"
    us-west-1 = "10.30.0.0/16"
    us-west-2 = "10.40.0.0/16"
}
ssh_ip_range = "xxx.xxx.xxx.xxx/32"
ssh_key_name = "dev"

nodes_per_region = 1
az_count = 1
vm_user = "debian"

cockroach_version = "25.4.3"
cluster_profile_name = "m6a-2xlarge"
cockroach_disk_size_gb = 50
cockroach_disk_type = "gp3"
cockroach_disk_iops = null
cockroach_disk_throughput = null

proxy_defaults = {
    instance_architecture = "amd64"
    instance_type = "c6a.large"
}
ha_node_count = 2
pgb_port = 5432
db_port = 26257
ui_port = 8080
EOF
```

You may also need to create a limited inline policy for your assigned role so that our HA solution can move the EIP during failover.  If a policy can't be created you can comment out the eni_role, eni_policy and eni_profile resources and the dcp_node iam_instance_profile in the dcp module of the terraform scripts, as well as the notify_master command of the keepalived.conf file configured in the dcp module cloud-init script.
```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowTerraformIAMForDCP",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PassRole",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:GetInstanceProfile"
      ],
      "Resource": [
        "arn:aws:iam::*:role/crdb-dcp-*",
        "arn:aws:iam::*:instance-profile/crdb-dcp-*"
      ]
    },
    {
      "Sid": "AllowEIPManagementForDCP",
      "Effect": "Allow",
      "Action": [
        "ec2:AllocateAddress",
        "ec2:ReleaseAddress",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress",
        "ec2:DescribeAddresses",
        "ec2:DescribeInstances",
        "ec2:DescribeNetworkInterfaces"
      ],
      "Resource": "*"
    }
  ]
}
```

Now we can run the controller to orchestrate the deployment and initialization of our cockroach cluster
```
export TF_VAR_ssh_public_key=$(cat ./my-safe-directory/dev.pub)
python controller.py \
  --ssh-user debian \
  --ssh-key ./my-safe-directory/dev \
  --apply \
  --terraform-dir ./terraform/aws \
  --tfvars-file crdb-dcp-test.tfvars \
  --ca-cert \
  --node-certs \
  --root-cert new \
  --dns-zone crdb-dcp-test.hutchandben.com \
  --certs-dir ./certs/crdb-dcp-test \
  --ca-key ./my-safe-directory/ca.key \
  --start-nodes new \
  --sql-users \
  --auth-mode cert \
  --num-connections 32 \
  --database defaultdb \
  --pgb-port 5432 \
  --db-port 26257 \
  --pgb-client-user jleelong \
  --pgb-server-user pgb






terraform -chdir=terraform/aws init
terraform -chdir=terraform/aws plan -var-file=crdb-dcp-test.tfvars
terraform -chdir=terraform/aws apply -var-file=crdb-dcp-test.tfvars

# confirm that the vpc exists, assuming you're connected to the same region
aws configure set region "us-east-2"
aws configure get region
aws ec2 describe-vpcs --filters Name=tag:Project,Values=jsonb-vs-text
aws ec2 describe-transit-gateways --query "TransitGateways[].TransitGatewayId"

# and check that the instances are up
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=jsonb-vs-text" \
  --query 'Reservations[].Instances[].{Name: Tags[?Key==`Name`]|[0].Value, State: State.Name}'

# connect to a node and run a few checks
CRDBNODE=$(terraform -chdir=terraform/aws output -json cockroach_nodes | jq -r '.["us-east-2"][0]["public_dns"]')
ssh -i ./my-safe-directory/dev debian@$CRDBNODE
lsblk
df -h | grep cockroach
ls -ltrh /var/lib/cockroach/certs
cockroach --version
exit

DCPNODE=$(terraform -chdir=terraform/aws output -json dcp_endpoints | jq -r '.["us-east-2"][0]["public_ip"]')
ssh -i ./my-safe-directory/dev debian@$DCPNODE
ls -ltrh /opt/dcp
ls -ltrh /etc/pgbouncer
ls -ltrh /usr/local/bin/claim-eip.sh
systemctl status pgbouncer-runner
systemctl status keepalived
exit
```

Then we can verify if our cockroach cluster is up and running
```
# copy the certs
mkdir -p certs
terraform output -raw cockroach_ca_cert > certs/ca.crt
terraform output -raw cockroach_node_cert > certs/node.crt
terraform output -raw cockroach_node_key > certs/node.key

HAPROXY=$(terraform -chdir=terraform/aws output -json haproxy_endpoints | jq -r '.["us-east-1"]')
```

Then check the status and configuration of our cluster
```
cockroach sql --url $CONN_STR -e "SHOW REGIONS FROM DATABASE defaultdb;"
cockroach sql --url $CONN_STR -e "SELECT node_id, locality, addr FROM crdb_internal.gossip_nodes ORDER BY node_id;"
```

**IMPORTANT**: when the workload test is complete don't forget to bring down the infrastructure for your cockroach multi-region cluster
```
terraform -chdir=terraform/aws destroy -var-file=crdb-dcp-test.tfvars
```
