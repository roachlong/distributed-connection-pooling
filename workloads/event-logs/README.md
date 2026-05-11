# Event Logs - Progressive Multi-Region Migration Demo

Demonstrates a **phased migration** from manual partitioning to full multi-region abstractions, showing how to evolve a geo-distributed application without downtime.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Initial Setup](#initial-setup)
- [Phase 1: Manual Partitioning](#phase-1-manual-partitioning--global-cdc)
- [Phase 2: Hybrid Multi-Region](#phase-2-hybrid-multi-region--account-migration)
- [Phase 3: Full Multi-Region](#phase-3-full-multi-region--regional-cdc)
- [Performance Analysis](#performance-analysis)
- [Cleanup](#cleanup)

## Overview

This workload demonstrates **progressive migration** from manual PARTITION BY to CockroachDB multi-region abstractions:

| Phase | Database Config | account_info | Other Tables | CDC | App Changes |
|-------|----------------|--------------|--------------|-----|-------------|
| **Phase 1** | No multi-region | Manual PARTITION BY | Regular tables | Global changefeed → `request-events` | None |
| **Phase 2** | Multi-region enabled | REGIONAL BY ROW AS computed_region | Regular tables | Global changefeed → `request-events` | Set `UseGeoPartitioning=true` |
| **Phase 3** | Multi-region enabled | REGIONAL BY ROW AS computed_region | REGIONAL BY ROW | Regional changefeeds → `request-events.{region}` | Update docker-compose topic names |

### Key Architecture

- **3 regional app instances** for RequestGenerator, WorkflowProcessor, TradeGenerator
- **Regional deployment** via docker-compose with environment variable overrides
- **PgBouncer VIPs** per region (172.18.0.251-253) for connection routing
- **Hybrid geo-partitioning**: account_info uses computed region, other tables use explicit crdb_region placement
- **Performance monitoring**: query-analysis daemon collects real-time metrics from crdb_internal tables

## Prerequisites

### Infrastructure

- **CockroachDB cluster** with regions us-east, us-central, us-west
- **PgBouncer instances** with regional VIPs (see main [DCP README](../../README.md))
- **Kafka** broker accessible at kafka:9093 (inside dcp-net) or localhost:9092 (from host)
- **Docker** with dcp-net network created
- **.NET 8 SDK** for building applications
- **Python 3.12+** with venv for query-analysis daemon

### Software Tools

```bash
# CockroachDB CLI
brew install cockroachdb/tap/cockroach

# Kafka CLI tools
brew install kafka

# .NET Entity Framework Core tools
dotnet tool install --global dotnet-ef
```

## Initial Setup

### 1. Build Docker Images

**IMPORTANT**: Build images first so containers use the latest code.

```bash
cd ~/workspace/distributed-connection-pooling/workloads/event-logs

# Build all application images with current code
docker-compose build

# This compiles .NET code and creates container images for:
# - account-batch-loader
# - request-generator (used for all 3 regional instances)
# - workflow-processor (used for all 3 regional instances)
# - trade-generator (used for all 3 regional instances)
# - analytics
```

### 2. Install Dependencies (Optional - only needed if modifying code)

```bash
# Install NuGet packages (Common, Data, Domain libraries)
dotnet add EventLogs.Common/EventLogs.Common.csproj package System.IO.Hashing --version 8.0.0
dotnet add EventLogs.Common/EventLogs.Common.csproj package Microsoft.Extensions.Logging.Abstractions --version 8.0.0
dotnet add EventLogs.Common/EventLogs.Common.csproj package Npgsql --version 8.0.5

dotnet add EventLogs.Data/EventLogs.Data.csproj package Microsoft.EntityFrameworkCore
dotnet add EventLogs.Data/EventLogs.Data.csproj package Npgsql.EntityFrameworkCore.PostgreSQL
dotnet add EventLogs.Data/EventLogs.Data.csproj package Microsoft.EntityFrameworkCore.Design

# Install app-specific packages
dotnet add EventLogs.WorkflowProcessor/EventLogs.WorkflowProcessor.csproj package Confluent.Kafka
dotnet add EventLogs.WorkflowProcessor/EventLogs.WorkflowProcessor.csproj package Microsoft.Extensions.Hosting
dotnet add EventLogs.TradeGenerator/EventLogs.TradeGenerator.csproj package Confluent.Kafka
dotnet add EventLogs.Analytics/EventLogs.Analytics.csproj package MudBlazor

# Add project references
for app in AccountBatchLoader RequestGenerator WorkflowProcessor TradeGenerator Analytics; do
  dotnet add EventLogs.$app/EventLogs.$app.csproj reference EventLogs.Common/EventLogs.Common.csproj
  dotnet add EventLogs.$app/EventLogs.$app.csproj reference EventLogs.Data/EventLogs.Data.csproj
  dotnet add EventLogs.$app/EventLogs.$app.csproj reference EventLogs.Domain/EventLogs.Domain.csproj
done
```

### 3. Verify Configuration Files

Your `.env` file should contain:

```bash
# .env file (already exists)
PGBOUNCER_VIP_US_EAST=172.18.0.251
PGBOUNCER_VIP_US_CENTRAL=172.18.0.252
PGBOUNCER_VIP_US_WEST=172.18.0.253
KAFKA_BOOTSTRAP=kafka:9093
LOCALITIES_US_EAST=[0,1,2,3,4,5,6,7,8,9]
LOCALITIES_US_CENTRAL=[10,11,12,13,14,15,16,17,18,19]
LOCALITIES_US_WEST=[20,21,22,23,24,25,26,27,28,29]
```

Each app has a single `appsettings.json` (already exists). Docker-compose overrides settings via environment variables.

### 4. Setup Query Analysis Daemon

```bash
# Create Python virtual environment
python3 -m venv .venv
source .venv/bin/activate  # or .venv\Scripts\activate on Windows
pip install psycopg psycopg-binary prometheus_client

# Start observability daemon (collects query stats to workload_test schema)
CERT_PATH=$(cd ../../certs && pwd)
export DATABASE_URL="postgresql://root@localhost:26257/defaultdb?sslmode=require&sslrootcert=${CERT_PATH}$/ca.crt&sslcert=${CERT_PATH}/client.root.crt&sslkey=${CERT_PATH}/client.root.key"
export METRICS_PORT=8001
nohup .venv/bin/python copy_obs_data.py > nohup.out 2>&1 & disown

# Verify it's running
ps aux | grep copy_obs_data.py
tail -f nohup.out

# After testing you can stop the daemon with
pkill -f copy_obs_data.py
```

## Phase 1: Manual Partitioning + Global CDC

**Goal**: Baseline performance with manual PARTITION BY and global Kafka topic.

### Step 1.1: Clean Database (if needed)

```bash
# Remove multi-region config if it exists
# Should return 0 rows
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -e "SHOW REGIONS FROM DATABASE defaultdb;"

# If regions exist, clean up
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f 00-cleanup-regions.sql
```

### Step 1.2: Initialize Schema

```bash
# Create tables with manual PARTITION BY for account_info
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f 01-initial-schema.sql

# Load configuration data (request types, statuses, workflow states)
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f 02-populate-static-data.sql

# Create Kafka partition coordination tables and functions
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f 03-kafka-partition-coordination-schema.sql

# Initialize partition tracking for request-events topic (24 partitions)
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -e "SELECT initialize_topic_partitions('request-events', 24);"

# Grant permissions to pgb user
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -e "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE defaultdb.* TO pgb;"
```

### Step 1.3: Create Global Kafka Topic

```bash
# Single global topic for all regions (consumer group distributes partitions)
kafka-topics --create \
  --bootstrap-server localhost:9092 \
  --topic request-events \
  --partitions 24 \
  --replication-factor 1

# Verify
kafka-topics --describe --bootstrap-server localhost:9092 --topic request-events
```

### Step 1.4: Create Global Changefeed

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
CREATE CHANGEFEED
  INTO 'kafka://kafka:9093?topic_name=request-events'
  WITH
    initial_scan = 'no',
    key_column = 'request_id',
    unordered,
    kafka_sink_config = '{"RequiredAcks": "ONE"}',
    cursor = 'now()'
  AS SELECT request_id, seq_num, action_state_link_id, status_id, 
            event_ts, actor, metadata, idempotency_key
  FROM request_event_log;
EOF

# Note: No WHERE crdb_region filter - this is a global changefeed
```

### Step 1.5: Register Test Run for Metrics Collection

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
INSERT INTO workload_test.test_run_configurations (
  test_run,
  database_name,
  start_time,
  end_time,
  agg_grace_interval
) VALUES (
  'phase-1-manual-partition',
  'defaultdb',
  now(),
  now() + interval '90 minutes',
  interval '5 minutes'
);
EOF
```

### Step 1.6: Run Regional Applications

**IMPORTANT**: No separate config files needed! Docker-compose uses environment variables to differentiate regions.

```bash
# Build all application images with current code
docker-compose build

# Load accounts (run once)
docker-compose up -d account-batch-loader
docker-compose logs -f account-batch-loader  # Wait for completion

# Start 3 RequestGenerator instances (one per region)
docker-compose up -d request-generator-us-east request-generator-us-central request-generator-us-west
docker-compose logs -f request-generator-us-east
# run for ~10 min
docker-compose stop request-generator-us-east request-generator-us-central request-generator-us-west

# Start 3 WorkflowProcessor instances (consume from shared topic via consumer group)
docker-compose up -d workflow-processor-us-east workflow-processor-us-central workflow-processor-us-west
docker-compose logs -f workflow-processor-us-east
# run for ~30 min
docker-compose stop workflow-processor-us-east workflow-processor-us-central workflow-processor-us-west

# Start 3 TradeGenerator instances
docker-compose up -d trade-generator-us-east trade-generator-us-central trade-generator-us-west
docker-compose logs -f trade-generator-us-east
# run for ~30 min
docker-compose stop trade-generator-us-east trade-generator-us-central trade-generator-us-west
```

**How regional config works**:
- Single `appsettings.json` per app with defaults
- `docker-compose.yml` defines 3 services per app (e.g., `workflow-processor-us-east`)
- Each service overrides via environment variables:
  - `ConnectionStrings__DefaultConnection` → regional VIP (from .env)
  - `Region` → us-east, us-central, us-west
  - `KafkaBootstrap` → kafka:9093
  - `Localities_us_east` → [0,1,2,3,4,5,6,7,8,9]

### Step 1.7: Analytics Web UI

The Analytics app is a Blazor Server web application that provides interactive visualizations and metrics for request status data across all three regions. It runs in Docker with access to regional PgBouncer VIPs.

```bash
docker restart $(docker ps -a --filter "name=^pgbouncer" --format "{{.Names}}")
docker-compose up -d analytics
```

Access the UI at: **http://localhost:5080**

Navigate to **Account Analytics** from the menu.

**Features:**
- Configure page size (100-10000) and concurrent tasks per region (1-50)
- Real-time progress tracking for each region
- Performance metrics: query count, avg response time, peak connections
- Interactive bar chart showing request counts by type and status
- Detailed data table with filtering
- Parallel pagination across all three regions with streaming updates

**How it works:**
- Connects to all three regional PgBouncer VIPs simultaneously
- Spawns configurable number of concurrent tasks per region
- Aggregates results client-side and streams updates via SignalR
- Tests connection pooling and parallel query performance

**Local development (optional):**
To run outside Docker for development with hot reload:
```bash
cd EventLogs.Analytics
dotnet run
```
Access at http://localhost:5000. Uses `appsettings.Development.json` which connects directly to CockroachDB (bypasses PgBouncer).

### Step 1.8: Stop Test Run

```bash
# Mark test run complete (stops metrics collection)
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
UPDATE workload_test.test_run_configurations
SET end_time = now()
WHERE test_run = 'phase-1-manual-partition';
EOF

cd ~/workspace/distributed-connection-pooling/workloads/event-logs
docker-compose down
```

## Phase 2: Hybrid Multi-Region + Account Migration

**Goal**: Enable multi-region, migrate account_info only, measure impact.

### Step 2.1: Run Migration Script

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f 04-migrate-account-to-regional.sql
```

This script:
1. Enables multi-region database (PRIMARY REGION, ADD REGION, SURVIVE REGION FAILURE)
2. Sets configuration tables to GLOBAL
3. Migrates account_info to REGIONAL BY ROW AS computed_region
4. Uses create-new, copy-data, rename-tables approach for minimal downtime

### Step 2.2: Update Application Config

**No code changes needed!** Just flip the UseGeoPartitioning flag:

Edit `docker-compose.yml` and add to each service's environment:
**NOTE excluding the Analytics app for now**
```yaml
  request-generator-us-east:
    environment:
      - UseGeoPartitioning=true  # Add this line
      # ... other env vars unchanged

  workflow-processor-us-east:
    environment:
      - UseGeoPartitioning=true  # Add this line
      # ... other env vars unchanged
      
  # Repeat for all regional services
```

Or update appsettings for each app to specify the same
```
  "UseGeoPartitioning": true,
```

**IMPORTANT**: Then rebuild your Docker images to pick up the config changes.

```bash
cd ~/workspace/distributed-connection-pooling/workloads/event-logs

# Build all application images with current code
docker-compose build

# This compiles .NET code and creates container images for:
# - account-batch-loader
# - request-generator (used for all 3 regional instances)
# - workflow-processor (used for all 3 regional instances)
# - trade-generator (used for all 3 regional instances)
# - analytics
```

This tells analytics queries to include `crdb_region` in WHERE clauses.

### Step 2.3: Register Phase 2 Test Run

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
INSERT INTO workload_test.test_run_configurations (
  test_run,
  database_name,
  start_time,
  end_time,
  agg_grace_interval
) VALUES (
  'phase-2-hybrid-regional',
  'defaultdb',
  now(),
  now() + interval '90 minutes',
  interval '5 minutes'
);
EOF
```

### Step 2.4: Restart Applications

**IMPORTANT**: No separate config files needed! Docker-compose uses environment variables to differentiate regions.

```bash
# Build all application images with current code
docker-compose build

# Load accounts (run once)
docker-compose up -d account-batch-loader
docker-compose logs -f account-batch-loader  # Wait for completion

# Start 3 RequestGenerator instances (one per region)
docker-compose up -d request-generator-us-east request-generator-us-central request-generator-us-west
docker-compose logs -f request-generator-us-east
# run for ~10 min
docker-compose stop request-generator-us-east request-generator-us-central request-generator-us-west

# Start 3 WorkflowProcessor instances (consume from shared topic via consumer group)
docker-compose up -d workflow-processor-us-east workflow-processor-us-central workflow-processor-us-west
docker-compose logs -f workflow-processor-us-east
# run for ~30 min
docker-compose stop workflow-processor-us-east workflow-processor-us-central workflow-processor-us-west

# Start 3 TradeGenerator instances
docker-compose up -d trade-generator-us-east trade-generator-us-central trade-generator-us-west
docker-compose logs -f trade-generator-us-east
# run for ~30 min
docker-compose stop trade-generator-us-east trade-generator-us-central trade-generator-us-west
```

**How regional config works**:
- Single `appsettings.json` per app with defaults
- `docker-compose.yml` defines 3 services per app (e.g., `workflow-processor-us-east`)
- Each service overrides via environment variables:
  - `ConnectionStrings__DefaultConnection` → regional VIP (from .env)
  - `Region` → us-east, us-central, us-west
  - `KafkaBootstrap` → kafka:9093
  - `Localities_us_east` → [0,1,2,3,4,5,6,7,8,9]

### Step 2.5: Analytics Web UI

The Analytics app is a Blazor Server web application that provides interactive visualizations and metrics for request status data across all three regions. It runs in Docker with access to regional PgBouncer VIPs.

```bash
docker restart $(docker ps -a --filter "name=^pgbouncer" --format "{{.Names}}")
docker-compose up -d analytics
```

Access the UI at: **http://localhost:5080**

Navigate to **Account Analytics** from the menu.

**Features:**
- Configure page size (100-10000) and concurrent tasks per region (1-50)
- Real-time progress tracking for each region
- Performance metrics: query count, avg response time, peak connections
- Interactive bar chart showing request counts by type and status
- Detailed data table with filtering
- Parallel pagination across all three regions with streaming updates

**How it works:**
- Connects to all three regional PgBouncer VIPs simultaneously
- Spawns configurable number of concurrent tasks per region
- Aggregates results client-side and streams updates via SignalR
- Tests connection pooling and parallel query performance

**Local development (optional):**
To run outside Docker for development with hot reload:
```bash
cd EventLogs.Analytics
dotnet run
```
Access at http://localhost:5000. Uses `appsettings.Development.json` which connects directly to CockroachDB (bypasses PgBouncer).

### Step 2.6: Stop Test Run

```bash
# Mark test run complete (stops metrics collection)
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
UPDATE workload_test.test_run_configurations
SET end_time = now()
WHERE test_run = 'phase-2-hybrid-regional';
EOF

cd ~/workspace/distributed-connection-pooling/workloads/event-logs
docker-compose down
```

## Phase 3: Full Multi-Region + Regional CDC

**Goal**: Migrate all tables, switch to regional changefeeds and topics.

### Step 3.1: Run Migration Script

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f 05-migrate-all-to-regional.sql
```

This migrates request_info, request_event_log, request_status_head, and trade_info to REGIONAL BY ROW, **explicitly setting crdb_region** to match account's computed_region for data co-location.

### Step 3.2: Create Regional Kafka Topics

```bash
kafka-topics --create --bootstrap-server localhost:9092 \
  --topic request-events.us-east --partitions 24 --replication-factor 1

kafka-topics --create --bootstrap-server localhost:9092 \
  --topic request-events.us-central --partitions 24 --replication-factor 1

kafka-topics --create --bootstrap-server localhost:9092 \
  --topic request-events.us-west --partitions 24 --replication-factor 1

# Initialize partition tracking for regional topics
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
SELECT initialize_topic_partitions('request-events.us-east', 24);
SELECT initialize_topic_partitions('request-events.us-central', 24);
SELECT initialize_topic_partitions('request-events.us-west', 24);
EOF
```

### Step 3.3: Drop Global Changefeed, Create Regional Changefeeds

```bash
# Find and cancel the global changefeed
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -e "SELECT job_id, description FROM [SHOW CHANGEFEED JOBS] WHERE status = 'running';"

# Cancel it (replace <job_id>)
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -e "CANCEL JOB <job_id>;"

# Create regional changefeeds
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f 06-create-regional-changefeeds.sql
```

### Step 3.4: Update Docker Compose for Regional Topics

Edit `docker-compose.yml` - change Kafka topic for workflow processors:

```yaml
  workflow-processor-us-east:
    environment:
      - KafkaTopic=request-events.us-east  # Add this line
      # ... other env vars

  workflow-processor-us-central:
    environment:
      - KafkaTopic=request-events.us-central  # Add this line

  workflow-processor-us-west:
    environment:
      - KafkaTopic=request-events.us-west  # Add this line
```

### Step 3.5: Register Phase 3 Test Run

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
INSERT INTO workload_test.test_run_configurations (
  test_run,
  database_name,
  start_time,
  end_time,
  agg_grace_interval
) VALUES (
  'phase-3-full-regional',
  'defaultdb',
  now(),
  now() + interval '90 minutes',
  interval '5 minutes'
);
EOF
```

### Step 3.6: Restart Applications

**IMPORTANT**: No separate config files needed! Docker-compose uses environment variables to differentiate regions.

```bash
# Build all application images with current code
docker-compose build

# Load accounts (run once)
docker-compose up -d account-batch-loader
docker-compose logs -f account-batch-loader  # Wait for completion

# Start 3 RequestGenerator instances (one per region)
docker-compose up -d request-generator-us-east request-generator-us-central request-generator-us-west
docker-compose logs -f request-generator-us-east
# run for ~10 min
docker-compose stop request-generator-us-east request-generator-us-central request-generator-us-west

# Start 3 WorkflowProcessor instances (consume from shared topic via consumer group)
docker-compose up -d workflow-processor-us-east workflow-processor-us-central workflow-processor-us-west
docker-compose logs -f workflow-processor-us-east
# run for ~30 min
docker-compose stop workflow-processor-us-east workflow-processor-us-central workflow-processor-us-west

# Start 3 TradeGenerator instances
docker-compose up -d trade-generator-us-east trade-generator-us-central trade-generator-us-west
docker-compose logs -f trade-generator-us-east
# run for ~30 min
docker-compose stop trade-generator-us-east trade-generator-us-central trade-generator-us-west
```

**How regional config works**:
- Single `appsettings.json` per app with defaults
- `docker-compose.yml` defines 3 services per app (e.g., `workflow-processor-us-east`)
- Each service overrides via environment variables:
  - `ConnectionStrings__DefaultConnection` → regional VIP (from .env)
  - `Region` → us-east, us-central, us-west
  - `KafkaBootstrap` → kafka:9093
  - `Localities_us_east` → [0,1,2,3,4,5,6,7,8,9]

### Step 3.7: Analytics Web UI

The Analytics app is a Blazor Server web application that provides interactive visualizations and metrics for request status data across all three regions. It runs in Docker with access to regional PgBouncer VIPs.

```bash
docker restart $(docker ps -a --filter "name=^pgbouncer" --format "{{.Names}}")
docker-compose up -d analytics
```

Access the UI at: **http://localhost:5080**

Navigate to **Account Analytics** from the menu.

**Features:**
- Configure page size (100-10000) and concurrent tasks per region (1-50)
- Real-time progress tracking for each region
- Performance metrics: query count, avg response time, peak connections
- Interactive bar chart showing request counts by type and status
- Detailed data table with filtering
- Parallel pagination across all three regions with streaming updates

**How it works:**
- Connects to all three regional PgBouncer VIPs simultaneously
- Spawns configurable number of concurrent tasks per region
- Aggregates results client-side and streams updates via SignalR
- Tests connection pooling and parallel query performance

**Local development (optional):**
To run outside Docker for development with hot reload:
```bash
cd EventLogs.Analytics
dotnet run
```
Access at http://localhost:5000. Uses `appsettings.Development.json` which connects directly to CockroachDB (bypasses PgBouncer).

### Step 3.8: Stop Test Run

```bash
# Mark test run complete (stops metrics collection)
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
UPDATE workload_test.test_run_configurations
SET end_time = now()
WHERE test_run = 'phase-3-full-regional';
EOF

cd ~/workspace/distributed-connection-pooling/workloads/event-logs
docker-compose down
```

## Validation

After running any phase, validate data locality alignment:

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f ./validation-queries.sql
```

### Key Validation Checks

The **Consolidated Scorecard** (Query #13) shows alignment scores:

| Check | Expected Score |
|-------|----------------|
| Request-Account Alignment | **100%** |
| Event-Request Alignment | **100%** |
| Trade-Account Alignment | **100%** |
| StatusHead-Request Alignment | **100%** |

Any score below 100% indicates data crossed region boundaries incorrectly.

See [validation-queries.sql](validation-queries.sql) for complete validation suite including:
- Leaseholder distribution by table
- Row counts by region
- Cross-region request detection
- Replica locality verification

## Performance Analysis

### Compare Phases

```bash
# Query workload_test schema for collected metrics
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
SELECT
  test_run,
  COUNT(*) AS query_count,
  AVG((statistics->'statistics'->'svcLat'->>'mean')::FLOAT) * 1000 AS avg_latency_ms,
  MAX((statistics->'statistics'->'latencyInfo'->>'max')::FLOAT) * 1000 AS max_latency_ms,
  MIN((statistics->'statistics'->'latencyInfo'->>'min')::FLOAT) * 1000 AS min_latency_ms,
  AVG((statistics->'statistics'->'runLat'->>'mean')::FLOAT) * 1000 AS avg_run_latency_ms
FROM workload_test.cluster_statement_statistics
WHERE test_run IN ('phase-1-manual-partition', 'phase-2-hybrid-regional', 'phase-3-full-regional')
GROUP BY test_run
ORDER BY test_run;
EOF
```

## Cleanup

```bash
# Stop all services
docker-compose down

# Clean database
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f cleanup-database.sql

# Clear Kafka topics
./cleanup-kafka-topics.sh

# Drop changefeeds
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -e "SELECT job_id FROM [SHOW CHANGEFEED JOBS];" \
  | tail -n +2 | xargs -I {} cockroach sql --certs-dir ../../certs \
    --url "postgresql://localhost:26257/defaultdb" -e "CANCEL JOB {};"
```

## Summary: What Changed Between Phases

| Aspect | Phase 1 | Phase 2 | Phase 3 |
|--------|---------|---------|---------|
| **Database** | No multi-region config | PRIMARY/ADD REGION, SURVIVE REGION | Same |
| **account_info** | PARTITION BY LIST + zone configs | REGIONAL BY ROW AS computed_region | Same |
| **Other tables** | Regular tables | Regular tables | REGIONAL BY ROW (explicit crdb_region) |
| **CDC** | 1 global changefeed | 1 global changefeed | 3 regional changefeeds |
| **Kafka topics** | `request-events` (global) | `request-events` (global) | `request-events.{region}` |
| **App config** | UseGeoPartitioning=false | UseGeoPartitioning=true | UseGeoPartitioning=true + KafkaTopic |
| **Code changes** | None | None | None |

## Architecture Details

For in-depth design patterns, rationale, and best practices, see:
- [ARCHITECTURE.md](ARCHITECTURE.md) - Complete architecture guide
- [RETRY_ERRORS_GUIDE.md](RETRY_ERRORS_GUIDE.md) - CockroachDB error handling and retry patterns
- [GEO-PARTITIONING-DESIGN.md](GEO-PARTITIONING-DESIGN.md) - Design checklist (older, pre-hybrid approach)

### Key Design Decisions

1. **Hybrid locality** - `account_info` uses computed hash; transactional tables use REGIONAL BY ROW
2. **Regional CDC topics** - 3 changefeeds with `WHERE crdb_region = ...` predicates
3. **Kafka offset pattern** - `EnableAutoCommit=true` + `EnableAutoOffsetStore=false` for safe replay
4. **Parallel keyset pagination** - Two-phase cursor-based pagination with concurrent page fetching (see below)
5. **Follower reads for analytics** - Uses `AS OF SYSTEM TIME follower_read_timestamp()` to distribute load across all replicas
6. **Trigger-maintained status** - `request_status_head` updated via trigger on `request_event_log`
7. **Error handling** - Common retry helper (`DatabaseRetryHelper`) handles serialization (40001), ambiguous (40003), connection (08xx/57xx), and duplicate key (23505) errors

### Parallel Keyset Pagination Pattern

The analytics service implements a **two-phase parallel pagination strategy** that dramatically improves performance for large dataset queries across multiple regions.

#### Traditional Keyset Pagination (Sequential)

```csharp
// ❌ Sequential - pages fetched one at a time
Guid? lastId = null;
while (true) {
    var page = await FetchPage(lastId, pageSize);
    if (page.Count == 0) break;
    lastId = page.LastId;  // Need this for next iteration
}
```

**Problem**: Each page query must wait for the previous one to complete, wasting time when you could be fetching multiple pages in parallel.

#### Our Approach: Pre-Computed Cursors + Parallel Fetch

**Phase 1: Pre-Compute All Page Cursors**

Uses window functions to find page boundaries **without fetching actual data**:

```sql
SELECT
    t.trade_id,
    t.rn,
    ((t.rn - 1) / @pageSize) + 1 as page_number
FROM (
    SELECT
        ti.trade_id,
        row_number() OVER (ORDER BY ti.trade_id) as rn
    FROM trade_info ti
    WHERE ti.crdb_region = @region
) t AS OF SYSTEM TIME follower_read_timestamp()
WHERE (t.rn - 1) % @pageSize = 0  -- Only first row of each page
ORDER BY t.trade_id
```

**Result**: A lightweight list of cursor positions (e.g., 10 cursors for 100K rows with 10K page size).

**Phase 2: Fetch All Pages in Parallel**

```csharp
// ✅ Parallel - all pages execute concurrently
var pageCursors = await GetPageCursorsAsync(region, pageSize);  // Fast query
var semaphore = new SemaphoreSlim(maxConcurrentTasks);

var pageTasks = pageCursors.Select(cursor => Task.Run(async () => {
    await semaphore.WaitAsync();
    try {
        return await FetchPageAsync(cursor);  // Each task gets its own cursor
    }
    finally {
        semaphore.Release();
    }
}));

var results = await Task.WhenAll(pageTasks);  // Wait for all pages
```

**Key Benefits**:
- **Parallelism**: All pages execute simultaneously (controlled by semaphore)
- **Connection pooling**: Each task gets its own connection from the pool
- **Real-time progress**: Metrics update as each page completes
- **No sequential dependency**: Don't need page N-1 to fetch page N

#### Performance Comparison

**Example**: 100K rows, 10K page size = 10 pages, 50ms per page query

| Strategy | Execution | Total Time |
|----------|-----------|------------|
| **Sequential Keyset** | Page 1 → wait → Page 2 → wait → ... | 10 × 50ms = **500ms** |
| **Parallel Cursors** | Cursor query (5ms) + max(50ms) for all pages | **~55ms** |

**~9x faster** for this workload!

#### Multi-Region Parallelism

The analytics service applies this pattern at **two levels**:

1. **Region-level parallelism**: 3 regions fetch in parallel via `Task.WhenAll`
2. **Page-level parallelism**: Within each region, N pages fetch in parallel (controlled by `maxConcurrentTasks`)

```
us-east (10 pages)     us-central (12 pages)    us-west (8 pages)
    ├─ Page 1              ├─ Page 1                ├─ Page 1
    ├─ Page 2              ├─ Page 2                ├─ Page 2
    ├─ ... (parallel)      ├─ ... (parallel)        ├─ ... (parallel)
    └─ Page 10             └─ Page 12               └─ Page 8
```

All 30 pages across all regions can execute concurrently!

#### Implementation Details

See `EventLogs.Analytics/Services/RegionalPaginationService.cs`:

- `GetPageCursorsAsync()` / `GetTradePageCursorsAsync()` - Phase 1 cursor discovery
- `FetchPageAsync()` / `FetchTradePageAsync()` - Individual page fetch with retry logic
- `FetchRegionalDataAsync()` / `FetchRegionalTradeDataAsync()` - Orchestrates parallel execution
- `DatabaseRetryHelper` - Wraps each query with exponential backoff retry for transient errors

**Follower Reads for Analytics**:

All analytics queries use `AS OF SYSTEM TIME follower_read_timestamp()` to enable **follower reads**:

```sql
SELECT ... 
FROM trade_info ti
AS OF SYSTEM TIME follower_read_timestamp()
WHERE ti.crdb_region = @region
```

**Why follower reads?**
- Analytics don't need real-time data (stale reads are acceptable)
- Queries can be served by **any replica** in the region (not just leaseholders)
- Distributes load across all 3 replicas per range (3x more capacity)
- Reduces contention on leaseholder nodes
- Lower latency when closest replica is not the leaseholder

**Staleness**: `follower_read_timestamp()` returns current time minus 4.8 seconds (default closed timestamp target). For analytics dashboards, this staleness is negligible.

**Connection Pool Configuration**:
- App pool: `Minimum Pool Size=2; Maximum Pool Size=150` per region
- PgBouncer: `default_pool_size=20-50` (backend connections)
- Result: 150 app connections share 20-50 backend connections efficiently
