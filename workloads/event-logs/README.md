# Event Logs

1. [Overview](#overview)
1. [What This Workload Demonstrates](#what-this-workload-demonstrates)
1. [Initial Setup](#initial-setup)
1. [Direct Connections](#direct-connections)
1. [Managed Connections](#managed-connections)
1. [Interpretation](#interpretation)

## Overview
This workload models a high-volume, multi-region **portfolio account management** platform. It simulates the lifecycle of account-centric requests and events across multiple services and regions: from account onboarding and profile changes, through entitlement updates and operational instructions (including, sometimes, rebalancing), to completion or failure.

The workload is designed around **geo-partitioned data**, **region-aware connection pooling**, and **change data capture (CDC)** driven orchestration using multiple .NET client applications.

### Logical Model

The schema represents four main domains.

#### 1. Static configuration (global)

These tables are small, read-mostly and LOCALITY GLOBAL:

<ins>request_type</ins> – classifies **account-related requests**, e.g.:
- ACCOUNT_ONBOARDING
- ACCOUNT_PROFILE_UPDATE
- ACCOUNT_PERMISSION_CHANGE
- ACCOUNT_CLOSE
- PORTFOLIO_REBALANCE_ADJUSTMENT

<ins>request_action_type</ins> – high-level actions in the workflow:
 - VALIDATE_REQUEST
 - COLLECT_DOCUMENTS
 - UPDATE_ACCOUNT
 - GENERATE_INSTRUCTIONS
 - etc.

<ins>request_state</ins> – fine-grained workflow states for actions:
- RECEIVED
- UNDER_REVIEW
- PENDING_APPROVAL
- PENDING_EXTERNAL_ACTION
- COMPLETED
- REJECTED…

<ins>request_action_state_link</ins> – allowed (request_type, action, state) combinations plus:
- is_initial / is_terminal flags
- sort_order for orchestration

<ins>request_status</ins> – coarse lifecycle status for a request or trade:
- IN_PROGRESS
- COMPLETE
- FAILED
- CANCELLED

These master tables define the “rules of the road” for how account management requests can flow.

#### 2. Accounts and requests (geo-partitioned)

These are **regionally sharded** and form the core of the workload.

<ins>account_info</ins> - Represents portfolios / client accounts, geo-partitioned by a hash-based locality on account_id.
Attributes might include:
- account number, account name
- strategy or segment
- base currency
- other static/profile fields

<ins>request_info</ins> - Represents **account management requests** that operate on one or more accounts, such as:
- open a new account
- update investment profile
- change contact / mailing preferences
- enable/disable a service or product
- apply allocation changes that may be triggered by rebalancing

Each request is:
- typed via request_type_id
- tied to a **primary_account_id**
- assigned a locality copied from that primary account so the request is co-located with the main portfolio
- tracked with a coarse request_status_id

<ins>request_account_link</ins> - A many-to-many table connecting requests to **all** affected accounts (not just the primary one). For example:
- a relationship change involving several related accounts
- a configuration change propagated to a group of accounts

This models account lifecycle and maintenance operations as explicit, trackable requests.

#### 3. Operational instructions (geo-partitioned)

<ins>trade_info (or more generically, “instruction_info”)</ins> - Represents **instructions generated as a consequence of account requests**.
In the context of account management, these can be:
- actual trades (e.g., allocation shifts caused by a profile change or rebalance adjustment)
- non-trade operational instructions (could be extended later)

For the workload, trades are sufficient to show:
- per-account operational impact of an account request
- how instructions are generated, updated, and monitored over time

All rows in trade_info are co-located with their parent request by copying the same locality.

#### 4. Event logging and current state (geo-partitioned)

<ins>request_event_log</ins> - An **append-only event stream** that captures each meaningful step in the lifecycle of a request, such as:
- validation started / completed
- documentation received
- account attributes updated
- downstream instructions generated / acknowledged
- request completed or failed

Each event includes:
- request_id, seq_num (per-request ordering)
- action_state_link_id (what action/state we moved into)
- status_id (meta status like IN_PROGRESS, COMPLETE, FAILED)
- timestamps, actor, and optional metadata
- the same locality as request_info, so events are co-located with the request

<ins>request_status_head</ins> - A small projection table that tracks the **current head state** per request:
- latest action_state_link_id
- status_id, event_ts, seq_num

It’s updated transactionally alongside request_event_log so hot reads don’t need to scan the event log.

### Workload Flow & Use Cases

The workload is driven by **two .NET apps** and **CDC into Kafka**, exercising both account-management logic and the underlying data/infra patterns.

#### App A – Account Management Request Producer

App A simulates front-office / client-facing systems that initiate **account events**, not just trades:
1. Creates or loads account_info records in different regions based on locality.
1. Creates new request_info records for account events:
    - e.g., “Update risk profile for Account 12345”
    - or “Onboard new account and attach it to household H”.
1. Populates request_account_link to capture all accounts impacted by the request.
1. Optionally creates initial trade_info (when the account change implies position changes).
1. Inserts initial entries into request_event_log and updates request_status_head.

Use cases tested:
- Region-aware **account and request writes** via PgBouncer.
- Locality propagation from account → request → trades → events.
- Throughput and latency under constant account-management request load.

#### CDC → Kafka

A changefeed streams changes from request_event_log (and/or request_status_head) into Kafka:
- Events include minimal identifiers: locality, request_id, seq_num, action_state_link_id, status_id, timestamps, and metadata.
- Kafka partitions can be keyed by request_id to preserve event order per request.

Use cases tested:
- CDC reliability and ordering for **account management events**.
- How an append-only request event stream can drive orchestration across services.
- Integration of CockroachDB CDC with a shared messaging fabric.

#### App B – Orchestrator / Worker

App B simulates back-office / middle-office services performing the **work required to complete account requests**:
1. Consumes account event messages from Kafka.
1. Uses locality in each message to select the correct **regional PgBouncer pool**.
1. Reads across:
    - request_info (what is this account request?)
    - request_account_link (which accounts are involved?)
    - account_info (current account details, region-local)
    - trade_info (operational instructions driven by this request)
1. Applies business logic, such as:
    - verifying that profile changes are valid
    - generating or adjusting instructions (including trades) if an account change requires portfolio adjustments
    - marking sub-tasks complete or failed
1. Emits new request_event_log entries and updates request_status_head until the account request reaches a terminal state (e.g. COMPLETED, FAILED, CANCELLED).

Use cases tested:
- **Locality-aware read/write** patterns with region-specific pools.
- Event-driven progression of account lifecycle requests.
- Idempotent processing and retriability of account events.

## What This Workload Demonstrates

### 1. Multi-Region Account Data Locality

account_info, request_info, trade_info, and request_event_log all share a **consistent locality key**, keeping:
- account data
- associated requests
- any instructions (trades)
- event logs

in the same region.  This reflects how a real portfolio platform might keep account operations near the “home” region of the client or household.

### 2. External Connection Pooling & Region-Aware Routing

- Multiple PgBouncer instances (one per region, HA).
- .NET clients computing or looking up locality and routing to the correct pool.
- Ability to benchmark:
    - centralized vs. region-aware pooling
    - pool size tuning under account-update workloads, not just trading.

### 3. Event-Driven Account Management Using CDC

- Append-only request_event_log as the **canonical record** of account events.
- CDC into Kafka to decouple event production (front-office) from processing (back-office).
- Optional request_status_head to show how you can derive:
    - cheap “current state” reads for dashboards and APIs, while
    - preserving the full event history for audit.

### 4. Contention & Throughput Under Frequent Status Updates

- Many small transactions:
    - appends to request_event_log
    - small UPSERTs to request_status_head
    - targeted updates to request_info and trade_info
- Indexes tuned for:
    - “latest event per request”
    - “all currently incomplete account requests”
- Demonstrates CockroachDB’s behavior under **high-frequency account lifecycle updates**.

### 5. Failure Handling & Idempotency in Account Workflows

- Idempotent event logging via idempotency_key.
- Safe replays in downstream services (App B) without double-processing requests.
- Observing how:
    - node failures,
    - PgBouncer restarts, or
    - consumer restarts

affect end-to-end account request processing.


## Initial Setup
First we'll execute the sql to create a sample schema and load some data into it.
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -f ./workloads/event-logs/initial-schema.sql
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -f ./workloads/event-logs/populate-sample-data.sql
```

Then permission access to the tables for our pgbouncer client.
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -e """
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE defaultdb.* TO pgb;
"""
```

### Change Feed

Next we'll create a kafka topic to publish new account request notifications from a CDC chnage feed.
```
kafka-topics --create \
  --bootstrap-server localhost:9092 \
  --topic acct-mgmt.new-request-events \
  --partitions 24 \
  --replication-factor 1

kafka-topics --describe \
  --bootstrap-server localhost:9092 \
  --topic acct-mgmt.new-request-events
```

And the change feed that will send new account request notifications
```
cockroach sql --certs-dir ./certs \
  --url "postgresql://localhost:26257/defaultdb" <<'EOF'
CREATE CHANGEFEED
  FOR TABLE request_info
  INTO 'kafka://kafka:9093?topic_name=acct-mgmt.new-request-events'
  WITH
    initial_scan      = 'no',
    envelope          = 'key_only',
    kafka_sink_config = '{"RequiredAcks": "ONE"}',
    cursor            = 'now()';
EOF
```

Then update a record and peek at the kafka topic to test the flow
```
cockroach sql --certs-dir ./certs --url "postgresql://localhost:26257/defaultdb" -e """
update request_info set requested_by = 'user_999'
where request_id = (select request_id from request_info limit 1);
"""

kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic acct-mgmt.new-request-events \
  --from-beginning \
  --max-messages 1 \
  --property print.key=true

# which should display the key set for the record we updated
["us-central", 11, "78ae6336-4364-41f8-8a8a-de210b95b0ea"]
```

### Project Structure

This is a one-time setup to create our project outline with Entity Framework Core
```
dotnet new sln -n EventLogsWorkflow

dotnet new classlib -n EventLogs.Domain
dotnet new classlib -n EventLogs.Data
dotnet new console  -n EventLogs.RequestGenerator
dotnet new console  -n EventLogs.RequestProcessor

dotnet sln EventLogsWorkflow.sln add \
  EventLogs.Domain/EventLogs.Domain.csproj \
  EventLogs.Data/EventLogs.Data.csproj \
  EventLogs.RequestGenerator/EventLogs.RequestGenerator.csproj \
  EventLogs.RequestProcessor/EventLogs.RequestProcessor.csproj

dotnet add EventLogs.Data/EventLogs.Data.csproj reference EventLogs.Domain/EventLogs.Domain.csproj
dotnet add EventLogs.RequestGenerator/EventLogs.RequestGenerator.csproj reference EventLogs.Data/EventLogs.Data.csproj
dotnet add EventLogs.RequestProcessor/EventLogs.RequestProcessor.csproj reference EventLogs.Data/EventLogs.Data.csproj
```

Add EF Core provider packages
```
dotnet add EventLogs.Data/EventLogs.Data.csproj package Microsoft.EntityFrameworkCore
dotnet add EventLogs.Data/EventLogs.Data.csproj package Npgsql.EntityFrameworkCore.PostgreSQL --version 8.0.10
dotnet add EventLogs.Data/EventLogs.Data.csproj package Npgsql --version 8.0.5
dotnet add EventLogs.Data/EventLogs.Data.csproj package CockroachDB.EFCore.Provider
```

Then scaffold DbContext & entities from the existing schema
```
dotnet tool install --global dotnet-ef
dotnet add EventLogs.Data/EventLogs.Data.csproj package Microsoft.EntityFrameworkCore.Design --version 8.0.10
dotnet add EventLogs.RequestGenerator/EventLogs.RequestGenerator.csproj package Microsoft.EntityFrameworkCore.Design --version 8.0.10

dotnet ef dbcontext scaffold \
  "Host=localhost;Port=26257;Database=defaultdb;Username=root;SSL Mode=Prefer;Root Certificate=../../../certs/ca.crt;SSL Certificate=../../../certs/client.root.crt;SSL Key=../../../certs/client.root.key" \
  Npgsql.EntityFrameworkCore.PostgreSQL \
  --context OptimaEventLogsContext \
  --context-dir ../EventLogs.Data/Context \
  --output-dir ../EventLogs.Domain/Models \
  --project EventLogs.Data \
  --startup-project EventLogs.RequestGenerator \
  --no-pluralize
```

And add dependencies for the EventLogs.RequestProcessor app
```
dotnet add EventLogs.RequestProcessor/EventLogs.RequestProcessor.csproj package Confluent.Kafka
dotnet add EventLogs.RequestProcessor/EventLogs.RequestProcessor.csproj package Microsoft.Extensions.Hosting
dotnet add EventLogs.RequestProcessor/EventLogs.RequestProcessor.csproj package Microsoft.Extensions.Logging.Console
```