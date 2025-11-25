# distributed-connection-pooling

1. [Overview](#overview)
1. [Solution Architecture](#solution-architecture)
1. [Test Results](#test-results)
1. [CockroachDB](#cockroachdb)
1. [PgBouncer](#pgbouncer)
1. [High Availability](#high-availability)
1. [Workload Tests](#workload-tests)

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

![Connection Swarm](./images/connection-swarm.svg)

**Symptoms**
- **Connection swarm**: N services × M pool size ⇒ **N×M sessions** on CRDB.
- **Starvation / head-of-line blocking**: Busy services grab connections while others sit idle; spikes cause thrash.
- **High session churn & metadata overhead**: DB spends cycles managing sessions instead of executing queries.
- **Operational sprawl**: Auth, timeouts, and limits duplicated across every app.

### Architecture (Solution): Distributed Connection Pooling with HA

Centralize connection lifecycle management behind a **stable VIP**. HAProxy handles frontend health/routing; PgBouncer multiplexes many client sessions onto a compact backend pool; Pacemaker/Corosync orchestrates failover and fencing.

![Distributed Connection Pooling](./images/distributed-connection-pooling.svg)

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

### Direct Connections
[<img src="images/direct-sql-activity.png">](./images/direct-sql-activity.png)

### Managed Connections
[<img src="images/pooling-sql-activity.png">](./images/pooling-sql-activity.png)

### Side-by-Side Metrics
Metrics collected from the database during both executions reveal significant differences in **internal transaction management and resource utilization**. The following charts present the two runs side by side.

| Metric | Direct Connections | Managed Connections |
| ------------- | ------------- | ------------- |
| Queries per Second | [<img src="images/direct-qps.png" width="250">](./images/direct-qps.png) | [<img src="images/pooling-qps.png" width="250">](./images/pooling-qps.png) |
| Service Latency | [<img src="images/direct-sql-latency.png" width="250">](./images/direct-sql-latency.png) | [<img src="images/pooling-sql-latency.png" width="250">](./images/pooling-sql-latency.png) |
| CPU Percent | [<img src="images/direct-cpu-pct.png" width="250">](./images/direct-cpu-pct.png) | [<img src="images/pooling-cpu-pct.png" width="250">](./images/pooling-cpu-pct.png) |
| Memory Usage | [<img src="images/direct-go-mem-usage.png" width="250">](./images/direct-go-mem-usage.png) | [<img src="images/pooling-go-mem-usage.png" width="250">](./images/pooling-go-mem-usage.png) |
| Read IOPS | [<img src="images/direct-read-iops.png" width="250">](./images/direct-read-iops.png) | [<img src="images/pooling-read-iops.png" width="250">](./images/pooling-read-iops.png) |
| Write IOPS | [<img src="images/direct-write-iops.png" width="250">](./images/direct-write-iops.png) | [<img src="images/pooling-write-iops.png" width="250">](./images/pooling-write-iops.png) |
| Open Sessions | [<img src="images/direct-open-sessions.png" width="250">](./images/direct-open-sessions.png) | [<img src="images/pooling-open-sessions.png" width="250">](./images/pooling-open-sessions.png) |
| Connection Rate | [<img src="images/direct-sql-connection-rate.png" width="250">](./images/direct-sql-connection-rate.png) | [<img src="images/pooling-sql-connection-rate.png" width="250">](./images/pooling-sql-connection-rate.png) |
| Open Transactions | [<img src="images/direct-open-txn.png" width="250">](./images/direct-open-txn.png) | [<img src="images/pooling-open-txn.png" width="250">](./images/pooling-open-txn.png) |
| SQL Contention | [<img src="images/direct-sql-contention.png" width="250">](./images/direct-sql-contention.png) | [<img src="images/pooling-sql-contention.png" width="250">](./images/pooling-sql-contention.png) |
| KV Latency | [<img src="images/direct-kv-latency.png" width="250">](./images/direct-kv-latency.png) | [<img src="images/pooling-kv-latency.png" width="250">](./images/pooling-kv-latency.png) |
| SQL Memory | [<img src="images/direct-sql-memory.png" width="250">](./images/direct-sql-memory.png) | [<img src="images/pooling-sql-memory.png" width="250">](./images/pooling-sql-memory.png) |
| WAL Sync Latency | [<img src="images/direct-wal-sync-latency.png" width="250">](./images/direct-wal-sync-latency.png) | [<img src="images/pooling-wal-sync-latency.png" width="250">](./images/pooling-wal-sync-latency.png) |
| Commit Latency | [<img src="images/direct-commit-latency.png" width="250">](./images/direct-commit-latency.png) | [<img src="images/pooling-commit-latency.png" width="250">](./images/pooling-commit-latency.png) |
| KV Slots Exhausted | [<img src="images/direct-kv-slots-exhausted.png" width="250">](./images/direct-kv-slots-exhausted.png) | [<img src="images/pooling-kv-slots-exhausted.png" width="250">](./images/pooling-kv-slots-exhausted.png) |
| IO Tokens Exhausted | [<img src="images/direct-adm-tokens-exhausted.png" width="250">](./images/direct-adm-tokens-exhausted.png) | [<img src="images/pooling-adm-tokens-exhausted.png" width="250">](./images/pooling-adm-tokens-exhausted.png) |
| CPU Queueing Delay | [<img src="images/direct-adm-queueing-delay.png" width="250">](./images/direct-adm-queueing-delay.png) | [<img src="images/pooling-adm-queueing-delay.png" width="250">](./images/pooling-adm-queueing-delay.png) |
| Scheduling Latency | [<img src="images/direct-go-sched-latency.png" width="250">](./images/direct-go-sched-latency.png) | [<img src="images/pooling-go-sched-latency.png" width="250">](./images/pooling-go-sched-latency.png) |

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

### What is CockroachDB?

**CockroachDB** is a **distributed SQL database** built for **global scale, strong consistency, and high resilience**. It’s wire-compatible with PostgreSQL, which means it supports the same SQL syntax, drivers, and tools — including PgBouncer — while providing automatic replication, fault tolerance, and horizontal scalability.

Unlike traditional databases that rely on a single primary node, CockroachDB distributes data automatically across multiple nodes. Each node can serve reads and writes, and the system ensures **ACID transactions** even in the presence of node or network failures. This makes it ideal for applications that require continuous availability and strong data integrity.

In this demo, CockroachDB serves as the **backend database** behind PgBouncer. While the example uses a single-node secure cluster for simplicity, the same principles apply to multi-node and multi-region deployments. The focus here is on the **connection management layer** — showing how PgBouncer can efficiently manage database sessions and reduce load on CockroachDB in high-concurrency environments.

### Why CockroachDB Benefits from Connection Pooling

Each connection to CockroachDB represents an active **SQL session** with its own memory context, transaction state, and session-level metadata. In busy application environments — particularly those with many microservices or short-lived requests — rapidly opening and closing connections can create overhead that limits scalability and increases latency.

Using **PgBouncer** as an intermediary allows applications to reuse a smaller set of persistent backend sessions while still handling thousands of concurrent client requests. This reduces pressure on CockroachDB’s session management layer, minimizes transaction contention, and ensures that the database remains focused on executing queries rather than maintaining idle connections.

Together, CockroachDB and PgBouncer form a robust foundation for **distributed, fault-tolerant connection management**, where scaling the application tier doesn’t compromise database performance or stability.

### CockroachDB Setup

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

## PgBouncer

### What is PgBouncer?

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

### Scale Network
Before we get started we'll need to increase the capacity of our docker network to handle 2048 connections
```
colima stop
colima start --network-address --memory 8 --cpu 4 --disk 100
```

Then increase the kernel and networking limits on the VM 
```
colima sh

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

### PgBouncer Setup

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

## High Availability

### What is HAProxy?

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

#### 1. Start by creating two containers using the host network so they can manipulate an IP on the host interface:
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

#### 2. And confirm that systemd is running inside each node
```
docker exec -it ha-node1 bash -lc 'systemctl is-system-running --wait || true; hostname -f'
docker exec -it ha-node2 bash -lc 'systemctl is-system-running --wait || true; hostname -f'
```

#### 3. Next enable pcsd and set the hacluster password on both nodes
```
for n in ha-node1 ha-node2; do
    docker exec -it $n bash -lc '
    systemctl enable --now pcsd &&
    echo -e "secret\nsecret" | passwd hacluster
    '
done
```

#### 4. Get each HA node’s IP (on dcp-net) and ensure node name resolution
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

#### 5. Configure Corosync with UDPU instead of multi-cast

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

#### 6. Bootstrap pacemaker properties but temporarily relax fencing/quorum
```
docker exec -it ha-node1 bash -lc '
  pcs property set stonith-enabled=false;
  pcs property set no-quorum-policy=ignore;
  pcs status
'
```
Should report both nodes Online: [ ha-node1 ha-node2 ].

#### 7. Create the VIP inside the Docker network

We picked 172.18.0.250/24; NIC is eth0 inside these containers:
```
VIP=172.18.0.250
docker exec -it ha-node1 bash -lc \
  "pcs resource create vip ocf:heartbeat:IPaddr2 ip=${VIP} cidr_netmask=24 nic=eth0 op monitor interval=30s; pcs status resources"
```

#### 8. Configure HAProxy and colocate it with the VIP

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

#### 9. Test from a client container on the same network

Your host can’t reach the VIP so we'll test from another container inside dcp-net.
```
docker run --rm -it --network dcp-net alpine sh -c "
  apk add --no-cache postgresql15-client curl >/dev/null && \
  echo 'Stats page:' && curl -s http://${VIP}:8404/stats | head -n 3 || true && \
  echo && echo 'psql via VIP:' && \
  psql 'postgresql://pgb:secret@${VIP}:5432/defaultdb?sslmode=prefer' -c 'show databases;'"
```

#### 10. Prove failover
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

#### 11. Enable dummy fencing for demonstration
```
docker exec -it ha-node1 bash -lc "
  pcs property set stonith-enabled=true;
  pcs stonith create fence-demo fence_dummy pcmk_host_list='ha-node1 ha-node2';
  pcs status"
```
In real VMs/hardware, replace fence_dummy with IPMI/libvirt/cloud agents.

#### 12. Some commands to verify status of HA cluster
```
docker exec -it ha-node1 bash -lc "pcs status"
docker exec -it ha-node1 bash -lc "corosync-cfgtool -s"
docker exec -it ha-node1 bash -lc "tail -n 100 /var/log/corosync/corosync.log"
```

#### 13. Create an entry point to the VIP
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

## Workload Tests

### Initial Schema
First we'll execute the sql to create a sample schema and load some data into it.
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -f ./sql/initial-schema.sql
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -f ./sql/populate-sample-data.sql
```

Then permission access to the tables for our pgbouncer client.
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -e """
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
* schedule_freq: the percentage of cycles we want to make updates to the flight schedule
* status_freq: the percentage of cycles we want to make updates to flight status
* inventory_freq: the percentage of cycles we want to make updates to the available seating
* price_freq: the percentage of cycles we want to make updates to the ticket prices
* batch_size: the number of records we want to update in a single cycle
* delay: the number of milliseconds we should pause between transactions, so we don't overload admission controls

These parameters are set in the run-workload.sh script.  We'll run multiple workers to simulate client apps (from a docker container) that run concurrently to process the total workload, each with a proportion of the total connection pool.  We'll pass the following parameters to the workload script.
* connection string: this is the uri we'll used to connect to the database
* test name: identifies the name of the test in the logs, i.e. direct
* txn poolimg: true if connections should be bound to the transaction, false for session
* total connections: the total number of connections we want to simulate across all workers
* num workers: the number of instances we want to spread the workload across

To execute the tests in docker we'll need to publish our python dependencies
```
pip freeze > requirements.txt
sed -E '/^(pyobjc-core|pyobjc-framework-Cocoa|py2app|rumps|macholib|tensorflow-macos|tensorflow-metal)(=|==)/d' \
  requirements.txt > requirements-runner.txt
```

### Direct Connections
Then we can use our workload script to simulate the workload going directly against the database running on our host machine.
```
export TEST_URI="postgresql://pgb:secret@host.docker.internal:26257/defaultdb?sslmode=prefer"
export TEST_NAME="direct"
export TXN_POOLONG="false"
./run_workloads.sh 1024 4
```
You can tail the files in the logs directory or open another terminal and run ```docker logs -f dbw-1```

A summary of the test results for our two workers are outlined below...
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

### Managed Connections
We can simulate the workload again, this time using our PgBouncer HA cluster with transaction pooling, but we'll have to disable prepared statements due to connection multiplexing between clients.
```
export TEST_URI="postgresql://pgb:secret@172.18.0.250:5432/defaultdb?sslmode=prefer"
export TEST_NAME="pooling"
export TXN_POOLONG="true"
./run_workloads.sh 1024 4
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

