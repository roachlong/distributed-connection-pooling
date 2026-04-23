# Event Logs - Multi-Region Account Management Workload

1. [Overview](#overview)
1. [Components](#components)
1. [Prerequisites](#prerequisites)
1. [Database Setup](#database-setup)
1. [Kafka Setup](#kafka-setup)
1. [CDC Changefeeds](#cdc-changefeeds)
1. [Project Structure](#project-structure)
1. [Running the Applications](#running-the-applications)
1. [Validation](#validation)
1. [Architecture Details](#architecture-details)

## Overview

This workload demonstrates a **hybrid geo-partitioning strategy** for a multi-region portfolio account management platform. It combines:

- **Smart client partitioning** for batch-loaded account data (computed locality hash)
- **Multi-region abstractions** (REGIONAL BY ROW) for transactional data that auto-homes via gateway locality
- **CDC-driven event orchestration** using regional Kafka topics
- **Keyset pagination** for efficient large-scale data processing

The system models the full lifecycle of account management requests: from onboarding and profile updates, through compliance workflows and trade generation, to completion and analytics.

### Key Capabilities Demonstrated

- **Data locality alignment** - Account data stays in its home region across all related tables
- **Regional app deployment** - Each app instance connects through regional LTM → PgBouncer → CRDB Gateway
- **Event-driven workflows** - CDC publishes to regional Kafka topics, consumers process locally
- **Keyset pagination** - Efficient traversal of large datasets without offset/skip anti-patterns
- **Manual offset management** - `EnableAutoCommit=true` + `EnableAutoOffsetStore=false` pattern for reliable replay
- **Cross-region analytics** - Parallel queries across all localities for global insights

## Components

| Component | Purpose | Regional Deployment |
|-----------|---------|---------------------|
| **AccountBatchLoader** | Loads account data with pre-computed locality hash | Single instance (any region) |
| **RequestGenerator** | Creates account management requests via keyset pagination | **3 instances** (one per region) |
| **WorkflowProcessor** | Consumes events from Kafka, progresses workflow state | **3 instances** (one per region) |
| **TradeGenerator** | Monitors completed requests, generates trades | **3 instances** (one per region) |
| **Analytics** | Blazor web UI with parallel cross-region pagination and visualizations | Single instance (web UI accessible at localhost:5080) |

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed design patterns and best practices.

## Prerequisites

- **CockroachDB** cluster (local or multi-region) configured with:
  - Primary region: `us-east`
  - Additional regions: `us-central`, `us-west`
  - Survival goal: `REGION FAILURE`
- **Kafka** broker accessible at `localhost:9092` (or configured endpoint)
- **PgBouncer** instances (optional, for connection pooling)
  - Recommended: 3 instances with LTM VIPs per region
  - See main [DCP README](../../README.md) for PgBouncer setup
- **.NET 8 SDK** installed
- **dotnet-ef** tool for scaffolding: `dotnet tool install --global dotnet-ef`

## Database Setup

### 1. Configure Multi-Region Database

If not already configured, set up the database for multi-region:

```bash
cockroach sql --certs-dir ../../certs --url "postgresql://localhost:26257/defaultdb" <<'EOF'
ALTER DATABASE defaultdb SET PRIMARY REGION "us-east";
ALTER DATABASE defaultdb ADD REGION "us-central";
ALTER DATABASE defaultdb ADD REGION "us-west";
ALTER DATABASE defaultdb SURVIVE REGION FAILURE;
EOF
```

### 2. Create Schema and Load Configuration Data

```bash
# Create tables (account_info, request_info, trade_info, etc.)
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f ./schema.sql

# Load global configuration tables (request types, statuses, workflow definitions)
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f ./populate-static-data.sql
```

### 3. Grant Permissions

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -e "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE defaultdb.* TO pgb;"
```

## Kafka Setup

### 1. Create Regional Topics

Create 3 topics (one per region) with multiple partitions for parallelism:

```bash
# us-east topic
kafka-topics --create \
  --bootstrap-server localhost:9092 \
  --topic request-events.us-east \
  --partitions 24 \
  --replication-factor 1

# us-central topic
kafka-topics --create \
  --bootstrap-server localhost:9092 \
  --topic request-events.us-central \
  --partitions 24 \
  --replication-factor 1

# us-west topic
kafka-topics --create \
  --bootstrap-server localhost:9092 \
  --topic request-events.us-west \
  --partitions 24 \
  --replication-factor 1
```

### 2. Verify Topics

```bash
kafka-topics --list --bootstrap-server localhost:9092

kafka-topics --describe \
  --bootstrap-server localhost:9092 \
  --topic request-events.us-east
```

## CDC Changefeeds

Create changefeeds to publish events from `request_event_log` to regional Kafka topics.

### us-east Changefeed

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
CREATE CHANGEFEED
  INTO 'kafka://kafka:9093?topic_name=request-events.us-east'
  WITH
    initial_scan = 'no',
    key_column = 'request_id',
    unordered,
    kafka_sink_config = '{"RequiredAcks": "ONE"}',
    cursor = 'now()'
  AS SELECT request_id, seq_num, action_state_link_id, status_id, 
            event_ts, actor, metadata, idempotency_key, crdb_region
  FROM request_event_log
  WHERE crdb_region = 'us-east';
EOF
```

### us-central Changefeed

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
CREATE CHANGEFEED
  INTO 'kafka://kafka:9093?topic_name=request-events.us-central'
  WITH
    initial_scan = 'no',
    key_column = 'request_id',
    unordered,
    kafka_sink_config = '{"RequiredAcks": "ONE"}',
    cursor = 'now()'
  AS SELECT request_id, seq_num, action_state_link_id, status_id, 
            event_ts, actor, metadata, idempotency_key, crdb_region
  FROM request_event_log
  WHERE crdb_region = 'us-central';
EOF
```

### us-west Changefeed

```bash
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
CREATE CHANGEFEED
  INTO 'kafka://kafka:9093?topic_name=request-events.us-west'
  WITH
    initial_scan = 'no',
    key_column = 'request_id',
    unordered,
    kafka_sink_config = '{"RequiredAcks": "ONE"}',
    cursor = 'now()'
  AS SELECT request_id, seq_num, action_state_link_id, status_id, 
            event_ts, actor, metadata, idempotency_key, crdb_region
  FROM request_event_log
  WHERE crdb_region = 'us-west';
EOF
```

### Test CDC Flow

Insert a test event and verify it appears in the correct regional topic:

```bash
# Insert a test event
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
-- Insert test account
INSERT INTO account_info (account_id, account_number, account_name, strategy, base_currency)
VALUES ('00000000-0000-0000-0000-000000000002', 'TEST-001', 'Test Account', 'Growth', 'USD');

-- Insert test request (will auto-home to region based on gateway)
INSERT INTO request_info (request_id, request_type_id, primary_account_id, requested_by, request_status_id)
SELECT gen_random_uuid(), 1, account_id, 'test_user', 1
FROM account_info WHERE account_number = 'TEST-001';

-- Insert test event (will auto-home to same region as request)
-- Note: idempotency_key should be deterministic (not random) for proper idempotency
WITH link AS (SELECT action_state_link_id AS id FROM request_action_state_link LIMIT 1)
INSERT INTO request_event_log (request_id, seq_num, action_state_link_id, status_id, idempotency_key)
SELECT request_id, 1, link.id, 1, 
       md5(request_id::STRING || '-' || link.id::STRING || '-test-initial')
FROM request_info, link WHERE requested_by = 'test_user';
EOF

# Check which topic received the event (based on your gateway region)
kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic request-events.us-east \
  --from-beginning \
  --max-messages 1 \
  --property print.key=true

# Cleanup test data
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
DELETE FROM request_event_log WHERE request_id IN (
  SELECT request_id FROM request_info WHERE requested_by = 'test_user'
);
DELETE FROM request_info WHERE requested_by = 'test_user';
DELETE FROM account_info WHERE account_number = 'TEST-001';
EOF
```

## Project Structure

The solution is organized into libraries and applications:

```
EventLogsWorkflow.sln
├── EventLogs.Common/          # Shared utilities (CRC32 hash, retry helpers, pagination)
├── EventLogs.Domain/          # EF Core entity models (scaffolded from schema)
├── EventLogs.Data/            # DbContext and repositories
├── EventLogs.AccountBatchLoader/      # App 1: Batch load accounts
├── EventLogs.RequestGenerator/        # App 2: Generate requests (3 regional instances)
├── EventLogs.WorkflowProcessor/       # App 3: Process events (3 regional instances)
├── EventLogs.TradeGenerator/          # App 4: Generate trades (3 regional instances)
└── EventLogs.Analytics/               # App 5: Blazor Server web UI with cross-region analytics
```

### Add NuGet Packages

```bash
# EventLogs.Common dependencies
dotnet add EventLogs.Common/EventLogs.Common.csproj package System.IO.Hashing
dotnet add EventLogs.Common/EventLogs.Common.csproj package Microsoft.Extensions.Logging.Abstractions --version 8.0.0
dotnet add EventLogs.Common/EventLogs.Common.csproj package Npgsql --version 8.0.5

# EventLogs.Data dependencies
dotnet add EventLogs.Data/EventLogs.Data.csproj package Microsoft.EntityFrameworkCore
dotnet add EventLogs.Data/EventLogs.Data.csproj package Npgsql.EntityFrameworkCore.PostgreSQL --version 8.0.10
dotnet add EventLogs.Data/EventLogs.Data.csproj package Npgsql --version 8.0.5
dotnet add EventLogs.Data/EventLogs.Data.csproj package Microsoft.EntityFrameworkCore.Design --version 8.0.10

# EventLogs.AccountBatchLoader dependencies
dotnet add EventLogs.AccountBatchLoader/EventLogs.AccountBatchLoader.csproj package Microsoft.Extensions.Configuration
dotnet add EventLogs.AccountBatchLoader/EventLogs.AccountBatchLoader.csproj package Microsoft.Extensions.Configuration.Json
dotnet add EventLogs.AccountBatchLoader/EventLogs.AccountBatchLoader.csproj package Microsoft.Extensions.Configuration.EnvironmentVariables
dotnet add EventLogs.AccountBatchLoader/EventLogs.AccountBatchLoader.csproj package Microsoft.Extensions.Logging.Console

# Project references
dotnet add EventLogs.Data/EventLogs.Data.csproj reference EventLogs.Domain/EventLogs.Domain.csproj
dotnet add EventLogs.Data/EventLogs.Data.csproj reference EventLogs.Common/EventLogs.Common.csproj

# Kafka consumers (WorkflowProcessor, TradeGenerator)
dotnet add EventLogs.WorkflowProcessor/EventLogs.WorkflowProcessor.csproj package Confluent.Kafka
dotnet add EventLogs.WorkflowProcessor/EventLogs.WorkflowProcessor.csproj package Microsoft.Extensions.Hosting
dotnet add EventLogs.WorkflowProcessor/EventLogs.WorkflowProcessor.csproj package Microsoft.Extensions.Logging.Console

dotnet add EventLogs.TradeGenerator/EventLogs.TradeGenerator.csproj package Confluent.Kafka
dotnet add EventLogs.TradeGenerator/EventLogs.TradeGenerator.csproj package Microsoft.Extensions.Hosting
dotnet add EventLogs.TradeGenerator/EventLogs.TradeGenerator.csproj package Microsoft.Extensions.Logging.Console

# Analytics Blazor Server app
dotnet add EventLogs.Analytics/EventLogs.Analytics.csproj package MudBlazor
dotnet add EventLogs.Analytics/EventLogs.Analytics.csproj package Microsoft.AspNetCore.SignalR.Client
dotnet add EventLogs.Analytics/EventLogs.Analytics.csproj package Npgsql.EntityFrameworkCore.PostgreSQL --version 8.0.10
dotnet add EventLogs.Analytics/EventLogs.Analytics.csproj package Microsoft.EntityFrameworkCore --version 8.0.10

# All apps need Common, Data, and Domain
for app in AccountBatchLoader RequestGenerator WorkflowProcessor TradeGenerator Analytics; do
  dotnet add EventLogs.$app/EventLogs.$app.csproj reference EventLogs.Common/EventLogs.Common.csproj
  dotnet add EventLogs.$app/EventLogs.$app.csproj reference EventLogs.Data/EventLogs.Data.csproj
  dotnet add EventLogs.$app/EventLogs.$app.csproj reference EventLogs.Domain/EventLogs.Domain.csproj
done
```

### Scaffold Domain Models

```bash
cd EventLogs.Data

dotnet ef dbcontext scaffold \
  "Host=localhost;Port=26257;Database=defaultdb;Username=root;SSL Mode=Prefer;Root Certificate=../../../certs/ca.crt;SSL Certificate=../../../certs/client.root.crt;SSL Key=../../../certs/client.root.key" \
  Npgsql.EntityFrameworkCore.PostgreSQL \
  --context EventLogsContext \
  --context-dir . \
  --output-dir ../EventLogs.Domain/Models \
  --no-pluralize \
  --force

cd ..
```

## Running the Applications

Applications run inside the **dcp-net** Docker network to access regional PgBouncer VIPs configured in the main DCP setup.

See the main [DCP README](../../README.md) for PgBouncer and VIP setup.

### Configuration

#### 1. Environment Variables (.env file)

Create a `.env` file in the `workloads/event-logs` directory with your VIP addresses:

```bash
# Regional PgBouncer VIP addresses (from DCP setup)
PGBOUNCER_VIP_US_EAST=172.18.0.251
PGBOUNCER_VIP_US_CENTRAL=172.18.0.252
PGBOUNCER_VIP_US_WEST=172.18.0.253

# Kafka broker
KAFKA_BOOTSTRAP=kafka:9093

# Database credentials
DB_NAME=defaultdb
DB_USER=pgb
DB_PASSWORD=secret

# Locality configuration (computed locality buckets per region)
# These arrays define which locality values (0-29) belong to each region
# Used by AccountBatchLoader and RequestGenerator for region-aligned queries
LOCALITIES_US_EAST=[0,1,2,3,4,5,6,7,8,9]
LOCALITIES_US_CENTRAL=[10,11,12,13,14,15,16,17,18,19]
LOCALITIES_US_WEST=[20,21,22,23,24,25,26,27,28,29]
```

Docker Compose will automatically load these variables and inject them into container environments.

**Why locality configuration?** The `account_info` table uses computed locality via `crc32ieee(account_id) % 30`, creating 30 buckets distributed across 3 regions (10 per region). Applications use these arrays to query accounts in their home region without hardcoding ranges.

#### 2. Application Settings (appsettings.json)

Each application needs an `appsettings.json` file. These are already created in each project directory:

**EventLogs.AccountBatchLoader/appsettings.json**:
```json
{
  "ConnectionStrings": {
    "DefaultConnection": "Host=pgbouncer;Port=5432;Database=defaultdb;Username=pgb;SSL Mode=Require;Trust Server Certificate=true;Pooling=true;Minimum Pool Size=10;Maximum Pool Size=200;Connection Lifetime=600;Connection Idle Lifetime=300;Application Name=eventlogs-account-batch-loader"
  },
  "BatchSize": 1000,
  "TotalAccounts": 30000,
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.EntityFrameworkCore": "Warning"
    }
  }
}
```

**EventLogs.RequestGenerator/appsettings.json**:
```json
{
  "ConnectionStrings": {
    "DefaultConnection": "Host=localhost;Port=26257;Database=defaultdb;Username=root;SSL Mode=Prefer;Root Certificate=../../../certs/ca.crt;SSL Certificate=../../../certs/client.root.crt;SSL Key=../../../certs/client.root.key;Pooling=true;Minimum Pool Size=10;Maximum Pool Size=200;Connection Lifetime=600;Connection Idle Lifetime=300;Application Name=eventlogs-request-generator"
  },
  "Region": "us-east",
  "BatchSize": 100,
  "ThrottleMs": 1000,
  "RequestedBy": "system"
}
```

**Note**: The `DefaultConnection` and region-specific settings are placeholders that will be overridden by environment variables in docker-compose.yml, which includes:
- The regional VIP from `.env` (e.g., `172.18.0.251` for us-east)
- Client certificate paths mounted from `../../certs/` directory
- Full SSL configuration required by PgBouncer
- Connection pooling parameters (see section below)
- Application Name for session identification in CockroachDB
- Locality arrays for the specific region

#### 3. Connection Pooling Configuration

All applications use **Npgsql connection pooling** on the client side, even though PgBouncer provides external pooling. This is critical for performance:

**Why client-side pooling matters with PgBouncer:**
- PgBouncer does transaction pooling/multiplexing (releases backend connections quickly)
- But apps still need TCP connections to PgBouncer
- Opening new connections has overhead: TCP handshake + SSL handshake
- Pre-warmed pool = fast connection acquisition for continuous workloads

**Connection String Parameters:**
```
Pooling=true                    # Enable pooling (default)
Minimum Pool Size=10            # Pre-warm 10 connections on startup
Maximum Pool Size=200           # Max 200 logical connections per instance
Connection Lifetime=600         # Refresh connections every 10 minutes
Connection Idle Lifetime=300    # Prune idle connections after 5 minutes
```

**Why these values:**
- **Minimum Pool Size=10**: Avoids cold start latency, keeps TCP/SSL connections ready
- **Maximum Pool Size=200**: Plenty of headroom for EF Core to use multiple connections per complex query
- **Connection Lifetime=600**: Balances connection reuse with periodic refresh
- Logical connections are cheap - we don't want the app blocking waiting for a connection object

These parameters are included in both `appsettings.json` defaults and docker-compose.yml environment overrides.

### Build and Run with Docker Compose

Applications are deployed incrementally - `docker-compose up -d` will start new services without restarting existing ones.

#### 1. Load Accounts (run once)

```bash
cd /path/to/workloads/event-logs

# Verify .env file exists with correct VIP addresses
cat .env

# Build and run account batch loader
docker-compose up -d account-batch-loader

# Watch logs
docker-compose logs -f account-batch-loader

# Wait for completion (container will exit when done)
```

if you need to start over after running any of the following services you can

1. Stop all running request generators:
```
cd /Users/jleelong/workspace/distributed-connection-pooling/workloads/event-logs

# i.e. stop all request generator instances
docker-compose stop request-generator-us-east request-generator-us-central request-generator-us-west

# or force kill them
docker-compose down request-generator-us-east request-generator-us-central request-generator-us-west
```

2. Clean up the database:
```
# Run the cleanup script (recreates the request status trigger)
cockroach sql --certs-dir ../../certs \
  --url "postgresql://localhost:26257/defaultdb" \
  -f ./cleanup-database.sql
```

3. Clear messages from Kafka topics:
```bash
# Uses Kafka UI REST API to clear all messages from the three regional topics
./cleanup-kafka-topics.sh

# Or manually via Kafka UI at: http://localhost:8088/ui/clusters/local/all-topics
```

4. And recreate the changefeeds above, which would have failed after truncating the data.

#### 2. Generate Requests (3 regional instances)

Each RequestGenerator instance:
- Uses keyset pagination to process accounts in its locality range
- Creates ACCOUNT_ONBOARDING requests for new accounts (no prior request_info)
- Creates random request types for existing accounts (excluding closed accounts)
- Writes to request_info and request_event_log (triggers CDC to Kafka)
- Runs continuously with configurable batch size and throttle

```bash
# Start RequestGenerator services (one per region)
docker-compose up -d request-generator-us-east request-generator-us-central request-generator-us-west

# Watch logs from all three instances
docker-compose logs -f request-generator-us-east request-generator-us-central request-generator-us-west
```

#### 3. Process Workflows (3 regional instances)

```bash
# Add WorkflowProcessor services - will be implemented next  
docker-compose up -d workflow-processor-us-east workflow-processor-us-central workflow-processor-us-west
```

#### 4. Generate Trades (3 regional instances)

```bash
# Add TradeGenerator services - will be implemented next
docker-compose up -d trade-generator-us-east trade-generator-us-central trade-generator-us-west
```

#### 5. Analytics Web UI

The Analytics app is a Blazor Server web application that provides interactive visualizations and metrics for request status data across all three regions. It runs in Docker with access to regional PgBouncer VIPs.

```bash
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

### Stop All Services

```bash
docker-compose down
```

## Validation

After running the workload, validate data locality alignment:

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

## Architecture Details

For in-depth design patterns, rationale, and best practices, see:
- [ARCHITECTURE.md](ARCHITECTURE.md) - Complete architecture guide
- [RETRY_ERRORS_GUIDE.md](RETRY_ERRORS_GUIDE.md) - CockroachDB error handling and retry patterns
- [GEO-PARTITIONING-DESIGN.md](GEO-PARTITIONING-DESIGN.md) - Design checklist (older, pre-hybrid approach)

### Key Design Decisions

1. **Hybrid locality** - `account_info` uses computed hash; transactional tables use REGIONAL BY ROW
2. **Regional CDC topics** - 3 changefeeds with `WHERE crdb_region = ...` predicates
3. **Kafka offset pattern** - `EnableAutoCommit=true` + `EnableAutoOffsetStore=false` for safe replay
4. **Keyset pagination** - Cursor-based (not offset) for efficient large dataset traversal
5. **Trigger-maintained status** - `request_status_head` updated via trigger on `request_event_log`
6. **Error handling** - Common retry helper (`DatabaseRetryHelper`) handles serialization (40001), ambiguous (40003), connection (08xx/57xx), and duplicate key (23505) errors

---

**Next Steps**: Continue building applications following the todo list. Start with AccountBatchLoader implementation.
