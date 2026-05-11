# Multi-Region Event-Driven Architecture

## Overview

This workload demonstrates a **progressive migration** from manual partitioning to multi-region abstractions:

**Phase 1**: Manual partitioning, global Kafka topics  
**Phase 2**: Multi-region enabled, hybrid partitioning (account_info migrated)  
**Phase 3**: All tables REGIONAL BY ROW, regional Kafka topics

**Final State - Hybrid Strategy**:
1. **account_info**: REGIONAL BY ROW with **computed region** (hash-based, deterministic)
2. **Other tables**: REGIONAL BY ROW with **gateway region** (dynamic, auto-homing)

---

## Architecture Evolution

### Phase 1: Manual Partitioning + Global CDC

```
Database: NO multi-region config
Apps: 3 regional instances (consistent across all phases)
Kafka: Global topics (all regions consume same topic)

┌──────────────────────────────────────────────────────────────┐
│ 1. AccountBatchLoader (3 instances, one per region)          │
│    ├─ Computes locality: crc32ieee(account_number) mod 30   │
│    ├─ Routes to regional gateway based on locality          │
│    └─ Writes to account_info (PARTITION BY LIST + zones)    │
└──────────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────────┐
│ 2. RequestGenerator (3 instances, one per region)            │
│    ├─ Connects via regional gateway                         │
│    ├─ Creates request_info (regular table)                  │
│    └─ Inserts request_event_log → triggers CDC              │
└──────────────────────────────────────────────────────────────┘
         ↓ CDC (single global changefeed)
┌──────────────────────────────────────────────────────────────┐
│ Kafka Topic: request-events (global, 24 partitions)          │
└──────────────────────────────────────────────────────────────┘
         ↓ (all 3 WorkflowProcessor instances consume)
┌──────────────────────────────────────────────────────────────┐
│ 3. WorkflowProcessor (3 instances, one per region)           │
│    ├─ All instances subscribe to SAME topic                 │
│    ├─ Consumer group distributes partitions across instances│
│    ├─ Each event processed by ONE instance only             │
│    └─ Writes to request_event_log (same region as gateway)  │
└──────────────────────────────────────────────────────────────┘
         ↓
┌──────────────────────────────────────────────────────────────┐
│ 4. TradeGenerator (3 instances, one per region)              │
│    └─ Writes to trade_info (regular table)                  │
└──────────────────────────────────────────────────────────────┘

Challenges:
- Manual zone config management
- Cannot use REGIONAL BY ROW
- All consumers see all events (Kafka partitions handle distribution)
```

---

### Phase 2: Multi-Region Enabled + Hybrid (account_info)

```
Database: Multi-region ENABLED
Apps: Same 3 regional instances (no changes)
Kafka: Still global topics (no changes)

┌──────────────────────────────────────────────────────────────┐
│ 1. AccountBatchLoader (3 instances, one per region)          │
│    ├─ Same code as Phase 1                                  │
│    └─ Writes to account_info (REGIONAL BY ROW, computed)    │
│        - locality: computed from account_number             │
│        - computed_region: computed from locality            │
│        - NO manual zone configs                             │
└──────────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────────┐
│ 2. RequestGenerator (3 instances, one per region)            │
│    ├─ Same code as Phase 1                                  │
│    └─ Creates request_info (still regular table)            │
└──────────────────────────────────────────────────────────────┘
         ↓ CDC (still single global changefeed)
┌──────────────────────────────────────────────────────────────┐
│ Kafka Topic: request-events (global)                         │
└──────────────────────────────────────────────────────────────┘
         ↓ (all 3 WorkflowProcessor instances consume)
┌──────────────────────────────────────────────────────────────┐
│ 3. WorkflowProcessor (3 instances, one per region)           │
│    └─ Same consumer group pattern as Phase 1                │
└──────────────────────────────────────────────────────────────┘

Benefits:
- Simplified account_info schema (no manual zone configs)
- Zero application code changes
- Same Kafka consumption pattern
```

---

### Phase 3: Full Multi-Region + Regional CDC

```
Database: Multi-region enabled
Apps: Same 3 regional instances (config changes only)
Kafka: Regional topics (3 topics per entity)

┌──────────────────────────────────────────────────────────────┐
│ 1. AccountBatchLoader (3 instances, one per region)          │
│    └─ Writes to account_info (REGIONAL BY ROW, computed)    │
│        [No changes from Phase 2]                             │
└──────────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────────┐
│ 2. RequestGenerator (3 instances, one per region)            │
│    ├─ Same code as Phase 1-2                                │
│    └─ Creates request_info (REGIONAL BY ROW, gateway)       │
│        - crdb_region: set by gateway_region()               │
└──────────────────────────────────────────────────────────────┘
         ↓ CDC (3 changefeeds, filtered by crdb_region)
┌──────────────────────────────────────────────────────────────┐
│ Kafka Topics (regional):                                     │
│  ├─ request-events.us-east (24 partitions)                   │
│  ├─ request-events.us-central (24 partitions)                │
│  └─ request-events.us-west (24 partitions)                   │
└──────────────────────────────────────────────────────────────┘
         ↓ (each WorkflowProcessor consumes its regional topic)
┌──────────────────────────────────────────────────────────────┐
│ 3. WorkflowProcessor (3 instances, one per region)           │
│    ├─ us-east instance → request-events.us-east             │
│    ├─ us-central instance → request-events.us-central       │
│    └─ us-west instance → request-events.us-west             │
│    └─ Writes to request_event_log (REGIONAL BY ROW)         │
└──────────────────────────────────────────────────────────────┘
         ↓
┌──────────────────────────────────────────────────────────────┐
│ 4. TradeGenerator (3 instances, one per region)              │
│    └─ Writes to trade_info (REGIONAL BY ROW, gateway)       │
└──────────────────────────────────────────────────────────────┘
         ↓ (cross-region analytics)
┌──────────────────────────────────────────────────────────────┐
│ 5. AnalyticsAggregator (web app, any region)                 │
│    ├─ Parallel queries across all regions                   │
│    ├─ Follower reads for better performance                 │
│    └─ Aggregates by account/strategy/symbol/region          │
└──────────────────────────────────────────────────────────────┘

Benefits:
- Auto-homing for ALL data
- Regional CDC reduces cross-region traffic
- Each instance processes only local events
- Follower reads for analytics
```

---

## Key Design Patterns

### 1. Hybrid Locality Strategy

**account_info (computed region - deterministic)**:
```sql
CREATE TABLE account_info (
    account_number STRING NOT NULL,
    locality INT2 AS (mod(crc32ieee(account_number), 30)::INT2) STORED,
    computed_region crdb_internal_region AS (
        CASE 
            WHEN locality BETWEEN 0 AND 9 THEN 'us-east'::crdb_internal_region
            WHEN locality BETWEEN 10 AND 19 THEN 'us-central'::crdb_internal_region
            ELSE 'us-west'::crdb_internal_region
        END
    ) STORED,
    PRIMARY KEY (locality, account_number)
) LOCALITY REGIONAL BY ROW AS computed_region;
```

**Characteristics**:
- Client provides business key (`account_number`)
- Database computes `locality` from hash
- Database computes `computed_region` from locality
- **No cross-region PK checks** (locality partitions keyspace)
- Deterministic placement (same account_number → same region)

**All other tables (gateway region - dynamic)**:
```sql
CREATE TABLE request_info (
    request_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    primary_account_number STRING NOT NULL,
    ...
) LOCALITY REGIONAL BY ROW;
-- Uses implicit gateway_region(), NOT computed
```

**Characteristics**:
- CockroachDB generates UUID
- `crdb_region` set by `gateway_region()` at insert time
- Dynamic placement based on which gateway processes write
- Simpler schema (no computed columns)

---

### 2. Regional App Deployment (Consistent Across All Phases)

Each app service is deployed **3 times** (one per region):

```
┌────────────┬─────────────────────────────────────────────────────┐
│ Service    │ Deployment Pattern                                  │
├────────────┼─────────────────────────────────────────────────────┤
│ us-east    │ → LTM VIP (us-east) → PgBouncer → Gateway (us-east)│
│ us-central │ → LTM VIP (us-central) → PgBouncer → Gateway (...) │
│ us-west    │ → LTM VIP (us-west) → PgBouncer → Gateway (us-west)│
└────────────┴─────────────────────────────────────────────────────┘
```

**Critical Configuration**:
- Each instance uses regional connection string
- Each instance connects to its regional gateway
- Kafka topic config changes in Phase 3 only

**appsettings.us-east.json**:
```json
{
  "ConnectionStrings": {
    "DefaultConnection": "Host=us-east-gateway;Port=26257;..."
  },
  "Region": "us-east",
  "UseGeoPartitioning": false,  // Phase 1-2
  // "UseGeoPartitioning": true, // Phase 3
  "KafkaTopic": "request-events",  // Phase 1-2
  // "KafkaTopic": "request-events.us-east"  // Phase 3
}
```

---

### 3. CDC Configuration Pattern

#### Phase 1-2: Global Changefeed

```sql
-- Single changefeed, all events to one topic
CREATE CHANGEFEED
INTO 'kafka://kafka:9093?topic_name=request-events'
WITH
  initial_scan = 'no',
  key_column = 'request_id',
  kafka_sink_config = '{"RequiredAcks": "ONE"}',
  format = 'json',
  envelope = 'wrapped'
AS SELECT request_id, seq_num, action_state_link_id, status_id, 
          event_ts, actor, metadata, idempotency_key
FROM request_event_log;
```

**Consumer Pattern** (all 3 instances share same topic):
```csharp
var config = new ConsumerConfig
{
    GroupId = "workflow-processor",  // Same group for all regions
    AutoOffsetReset = AutoOffsetReset.Earliest
};

consumer.Subscribe("request-events");  // All instances subscribe
// Kafka partitions distributed across 3 instances
// Each event processed by ONE instance
```

#### Phase 3: Regional Changefeeds

```sql
-- 3 changefeeds, one per region (using CDC queries)
CREATE CHANGEFEED
INTO 'kafka://kafka:9093?topic_name=request-events.us-east'
WITH
  initial_scan = 'no',
  key_column = 'request_id',
  kafka_sink_config = '{"RequiredAcks": "ONE"}',
  format = 'json',
  envelope = 'wrapped'
AS SELECT * FROM request_event_log WHERE crdb_region = 'us-east';

-- Repeat for us-central and us-west
```

**Consumer Pattern** (each instance consumes regional topic):
```csharp
var config = new ConsumerConfig
{
    GroupId = $"workflow-processor-{region}",  // Regional group
    AutoOffsetReset = AutoOffsetReset.Earliest
};

consumer.Subscribe($"request-events.{region}");  // Regional topic
// us-east instance only sees us-east events
```

**Benefits of Regional CDC**:
- ✅ Reduced cross-region network traffic
- ✅ Each instance processes only local events
- ✅ Better locality of processing
- ✅ Smaller topic sizes (events distributed across 3 topics)

---

### 4. Kafka Consumer Pattern (Manual Offset Store + Auto Commit)

Consistent across all phases:

```csharp
var config = new ConsumerConfig
{
    BootstrapServers = kafkaBootstrap,
    GroupId = groupId,  // Changes based on phase
    AutoOffsetReset = AutoOffsetReset.Earliest,
    EnableAutoCommit = true,           // Kafka auto-commits stored offsets
    EnableAutoOffsetStore = false      // Manual control of when to store
};

using var consumer = new ConsumerBuilder<string, string>(config).Build();
consumer.Subscribe(topic);  // Global or regional based on phase

while (!stoppingToken.IsCancellationRequested)
{
    var result = consumer.Consume(stoppingToken);
    
    try
    {
        // Process message
        await ProcessEventAsync(result.Message);
        
        // Only store offset after successful processing
        consumer.StoreOffset(result);
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Processing failed, will retry");
        // Don't store offset - message will be re-consumed
    }
}
```

**Why this pattern?**:
- ✅ At-least-once delivery guarantee
- ✅ Automatic background commits (no blocking)
- ✅ Manual control over which offsets to commit
- ✅ Failed messages automatically retried

---

### 5. Distributed Partition Coordination

Each WorkflowProcessor instance dynamically claims partitions based on peer count, ensuring:
- **Exactly-one-consumer per partition** (guaranteed message ordering)
- **Automatic load balancing** (fair distribution across instances)
- **Graceful failover** (orphaned partitions automatically reassigned)

#### Architecture

Each instance runs a local coordination agent that:
1. Registers itself in `kafka_consumers` table
2. Counts active peers via heartbeat timestamps
3. Calculates fair share: `⌈partitionCount / activeConsumers⌉`
4. Claims/releases partitions to match fair share
5. Sends heartbeats every 10 seconds
6. Detects failed peers (30s timeout)

**Database Schema** ([kafka-partition-coordination-schema.sql](kafka-partition-coordination-schema.sql)):

```sql
-- Consumer registration
CREATE TABLE kafka_consumers (
    consumer_id       STRING PRIMARY KEY,
    hostname          STRING NOT NULL,
    last_heartbeat    TIMESTAMPTZ NOT NULL DEFAULT now(),
    partition_capacity INT4 NOT NULL DEFAULT 24,
    current_partitions INT4 NOT NULL DEFAULT 0,
    is_healthy        BOOL NOT NULL DEFAULT true
);

-- Partition ownership tracking
CREATE TABLE kafka_partition_assignments (
    topic             STRING NOT NULL,
    partition_id      INT4 NOT NULL,
    consumer_id       STRING NULL,
    consumer_hostname STRING NULL,
    assigned_at       TIMESTAMPTZ NULL,
    last_heartbeat    TIMESTAMPTZ NULL,
    last_offset       INT8 NULL,
    messages_processed INT8 DEFAULT 0,
    reassignment_count INT4 DEFAULT 0,
    PRIMARY KEY (topic, partition_id)
);

-- Atomic claim using SERIALIZABLE isolation
CREATE OR REPLACE FUNCTION claim_partition(
    p_topic STRING, p_partition INT4, 
    p_consumer_id STRING, p_hostname STRING
) RETURNS BOOL AS $$
BEGIN
    SELECT consumer_id, last_heartbeat 
    FROM kafka_partition_assignments
    WHERE topic = p_topic AND partition_id = p_partition
    FOR UPDATE;  -- Row-level lock
    
    -- Available if unassigned or heartbeat timed out
    IF consumer_id IS NULL OR now() - last_heartbeat > INTERVAL '30 seconds' THEN
        UPDATE kafka_partition_assignments
        SET consumer_id = p_consumer_id, 
            assigned_at = now(), 
            last_heartbeat = now(),
            reassignment_count = reassignment_count + 1
        WHERE topic = p_topic AND partition_id = p_partition;
        RETURN true;
    END IF;
    RETURN false;
END;
$$ LANGUAGE plpgsql;
```

#### Load Balancing Examples

24 partitions auto-balance across varying instance counts:

```
┌───────────┬─────────────────┬─────────────────────────────┐
│ Instances │ Partitions/Each │ Mechanism                   │
├───────────┼─────────────────┼─────────────────────────────┤
│ 1         │ 24              │ Claims all partitions       │
│ 2         │ 12              │ Each claims 12              │
│ 3         │ 8               │ Each claims 8               │
│ 4         │ 6               │ Each claims 6               │
│ 5         │ 4-5             │ Uneven: 5,5,5,5,4           │
│ 8         │ 3               │ Each claims 3               │
│ 12        │ 2               │ Each claims 2               │
│ 24        │ 1               │ Each claims 1 partition     │
└───────────┴─────────────────┴─────────────────────────────┘
```

#### Dynamic Scaling Scenarios

**Scenario 1: Scale up (1 → 3 instances)**
```
t=0s:  Instance A starts, claims partitions 0-23 (all 24)
       Consumer threads: 24 active

t=30s: Instance B starts, registers as peer
       Both instances see 2 peers, recalculate: 24/2 = 12 each
       Instance A releases partitions 12-23
       Instance B claims partitions 12-23
       Consumer threads: A=12, B=12

t=60s: Instance C starts, registers as peer
       All instances see 3 peers, recalculate: 24/3 = 8 each
       Instance A releases partitions 8-11
       Instance B releases partitions 20-23
       Instance C claims partitions 8-11, 20-23
       Consumer threads: A=8, B=8, C=8
```

**Scenario 2: Failure recovery (3 → 2 instances)**
```
t=0s:  Instances A, B, C each own 8 partitions
       Consumer threads: A=8, B=8, C=8

t=10s: Instance C crashes (no graceful shutdown)
       Partitions 16-23 orphaned
       Last heartbeat from C: t=10s

t=40s: Instances A and B detect timeout (now=t=40s, last=t=10s, delta=30s)
       Both see 2 healthy peers, recalculate: 24/2 = 12 each
       Instance A claims partitions 16-19 (now owns 0-7, 16-19 = 12 total)
       Instance B claims partitions 20-23 (now owns 8-11, 20-23 = 12 total)
       Consumer threads: A=12, B=12
       Zero message loss, automatic failover
```

**Scenario 3: Graceful shutdown**
```
t=0s:  Instances A, B, C each own 8 partitions
       Consumer threads: A=8, B=8, C=8

t=5s:  Instance C receives SIGTERM, begins shutdown
       - Stops heartbeat background task
       - Cancels partition consumer threads
       - Calls release_partition() for all owned partitions
       - Updates kafka_consumers: is_healthy=false
       Partitions 16-23 immediately available (consumer_id=NULL)

t=10s: Instances A and B detect 2 healthy peers (C marked unhealthy)
       Recalculate: 24/2 = 12 each
       Instance A claims partitions 16-19
       Instance B claims partitions 20-23
       Consumer threads: A=12, B=12
       Faster recovery than crash (no 30s timeout wait)
```

#### Implementation

**KafkaPartitionCoordinator.cs** ([source](EventLogs.Common/KafkaPartitionCoordinator.cs)):

```csharp
public class KafkaPartitionCoordinator : IAsyncDisposable
{
    private readonly HashSet<int> _ownedPartitions = new();
    
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        // Register this consumer instance
        await RegisterConsumerAsync();
        
        // Background: heartbeat every 10s
        _heartbeatTask = Task.Run(() => HeartbeatLoopAsync(cancellationToken));
        
        // Background: claim/release partitions every 5s
        _claimTask = Task.Run(() => ClaimPartitionsLoopAsync(cancellationToken));
    }
    
    private async Task ClaimAvailablePartitionsAsync()
    {
        // Calculate fair share based on active peers
        var (totalConsumers, fairShare) = await CalculateFairShareAsync();
        
        // Rebalance: release excess partitions
        if (_ownedPartitions.Count > fairShare + 1)
        {
            var excess = _ownedPartitions.Count - fairShare;
            foreach (var partition in PartitionsToRelease(excess))
                await ReleasePartitionAsync(partition, "rebalance");
            return;
        }
        
        // Claim orphaned partitions up to fair share
        var available = await FindOrphanedPartitionsAsync(fairShare - _ownedPartitions.Count);
        foreach (var partition in available)
        {
            if (await TryClaimPartitionAsync(partition))
                _ownedPartitions.Add(partition);
        }
    }
    
    private async Task<(int totalConsumers, int fairShare)> CalculateFairShareAsync()
    {
        // Count healthy consumers (heartbeat within 30s)
        var totalConsumers = await CountHealthyConsumersAsync();
        var fairShare = totalConsumers > 0 
            ? (_partitionCount + totalConsumers - 1) / totalConsumers  // Ceiling division
            : _partitionCount;
        return (totalConsumers, fairShare);
    }
}
```

**WorkflowProcessor Integration**:

```csharp
// Start coordinator
var coordinator = new KafkaPartitionCoordinator(
    connectionString, topic, partitionCount, 
    maxPartitionsPerConsumer: partitionCount, logger);
await coordinator.StartAsync(cts.Token);

// Dynamic partition management loop
var partitionTasks = new Dictionary<int, (Task, CancellationTokenSource)>();
while (!cts.Token.IsCancellationRequested)
{
    var ownedPartitions = coordinator.GetOwnedPartitions();
    var ownedSet = new HashSet<int>(ownedPartitions);
    var runningSet = new HashSet<int>(partitionTasks.Keys);
    
    // Start consumers for newly claimed partitions
    foreach (var partition in ownedSet.Except(runningSet))
    {
        var partitionCts = CancellationTokenSource.CreateLinkedTokenSource(cts.Token);
        var task = Task.Run(() => ProcessPartition(partition, ..., partitionCts.Token));
        partitionTasks[partition] = (task, partitionCts);
    }
    
    // Stop consumers for released partitions
    foreach (var partition in runningSet.Except(ownedSet))
    {
        partitionTasks[partition].Item2.Cancel();
        await partitionTasks[partition].Item1;
        partitionTasks.Remove(partition);
    }
    
    await Task.Delay(5000);  // Check every 5s
}
```

#### Benefits

- ✅ **Guaranteed ordering**: One consumer per partition, messages processed in sequence
- ✅ **Zero duplication**: SERIALIZABLE isolation prevents race conditions
- ✅ **Automatic failover**: Dead consumers detected via heartbeat timeout (30s)
- ✅ **Elastic scaling**: Add/remove instances without manual coordination
- ✅ **Graceful shutdown**: Partitions released immediately, faster reassignment
- ✅ **Self-healing**: Orphaned partitions automatically claimed
- ✅ **Observable**: Monitoring views show partition distribution and consumer health

#### Monitoring Queries

```sql
-- Current partition distribution
SELECT * FROM v_partition_distribution;

-- Orphaned partitions (need reassignment)
SELECT * FROM v_orphaned_partitions;

-- Consumer health overview
SELECT * FROM v_consumer_health;

-- Partition assignment history (debugging failovers)
SELECT topic, partition_id, consumer_id, assigned_at, released_at, reason
FROM kafka_partition_assignment_history
WHERE topic = 'request-events.us-east'
ORDER BY assigned_at DESC
LIMIT 100;
```

---

### 6. Account Data Flow (Hybrid Approach)

**Phase 1 (Manual Partitioning)**:
```
AccountBatchLoader:
1. account_number = "ACCT-00000123"
2. locality = crc32("ACCT-00000123") % 30 = 7  (computed by app)
3. INSERT (account_number, ...) to us-east gateway
4. Database computes locality = 7 (stored in table)
5. Data lands in us_east partition via zone config
```

**Phase 2+ (REGIONAL BY ROW with computed region)**:
```
AccountBatchLoader:
1. account_number = "ACCT-00000123"
2. INSERT (account_number, ...) to any gateway
3. Database computes locality = 7 from account_number
4. Database computes computed_region = 'us-east' from locality
5. Data lands in us-east region via REGIONAL BY ROW
```

**Key Point**: Application code unchanged between phases!

---

### 7. Request Data Flow (Gateway-Based)

**Phase 1-2**:
```
RequestGenerator (us-east instance):
1. Connect to us-east gateway
2. INSERT (primary_account_number, requested_by, ...)
   -- request_id: generated by app or database
3. Data lands in... wherever (no partitioning)
```

**Phase 3**:
```
RequestGenerator (us-east instance):
1. Connect to us-east gateway
2. INSERT (primary_account_number, requested_by, ...)
   -- request_id: generated by database (UUID)
   -- crdb_region: set to 'us-east' by gateway_region()
3. Data lands in us-east region via REGIONAL BY ROW
```

---

### 8. Follower Reads for Analytics (Phase 2+)

```csharp
// Phase 1: Must read from leaseholders
var accounts = await context.AccountInfo
    .Where(a => a.AccountName.Contains(searchTerm))
    .ToListAsync();

// Phase 2+: Can use follower reads (3x capacity)
var accounts = await context.AccountInfo
    .FromSqlRaw(@"
        SELECT *
        FROM account_info
        AS OF SYSTEM TIME follower_read_timestamp()
        WHERE computed_region = {0}
          AND account_name LIKE {1}
    ", region, $"%{searchTerm}%")
    .ToListAsync();
```

**Benefits**:
- ✅ Read from any replica (not just leaseholder)
- ✅ 3x read capacity for analytics
- ✅ Reduced leaseholder contention
- ✅ Better performance for AnalyticsAggregator

---

## Data Model Relationships

```
┌─────────────────────────────────────────────────────────────┐
│ account_info (REGIONAL BY ROW, computed region)             │
│ ├─ Primary Key: (locality, account_number)                  │
│ ├─ locality: computed from account_number                   │
│ └─ computed_region: computed from locality                  │
│     - Deterministic placement                                │
│     - No cross-region PK checks                              │
└─────────────────────────────────────────────────────────────┘
         ↑ (FK reference)
┌─────────────────────────────────────────────────────────────┐
│ request_info (REGIONAL BY ROW, gateway region)              │
│ ├─ Primary Key: request_id (UUID)                           │
│ ├─ crdb_region: set by gateway_region()                     │
│ └─ primary_account_number: FK to account_info               │
│     - May reference account in different region             │
│     - CockroachDB validates FK across regions               │
└─────────────────────────────────────────────────────────────┘
         ↑ (FK reference)
┌─────────────────────────────────────────────────────────────┐
│ request_event_log (REGIONAL BY ROW, gateway region)         │
│ ├─ Primary Key: (request_id, seq_num)                       │
│ ├─ crdb_region: set by gateway_region()                     │
│ └─ Follows request to same region (semantic locality)       │
└─────────────────────────────────────────────────────────────┘
```

**Cross-Region Foreign Keys**:
- Request in us-east can reference account in us-central
- CockroachDB validates FK across regions (tolerable overhead)
- Most requests reference local accounts (semantic locality)
- Flexibility is worth occasional cross-region check

---

## Performance Characteristics

### Writes

| Table | Phase 1-2 | Phase 3 | Cross-Region PK Checks |
|-------|-----------|---------|------------------------|
| account_info | Single-region | Single-region | ❌ None (locality partitions) |
| request_info | Any region | Single-region | N/A (UUID) |
| request_event_log | Any region | Single-region | N/A (composite) |
| trade_info | Any region | Single-region | N/A (UUID) |

### Reads

| Operation | Phase 1 | Phase 2+ |
|-----------|---------|----------|
| Leaseholder reads | Required | Optional |
| Follower reads | ❌ Not available | ✅ Available |
| Read capacity | 1x (leaseholders only) | 3x (all replicas) |
| Analytics queries | Slower | Faster |

### Network Traffic

| Phase | CDC Pattern | Cross-Region Traffic |
|-------|-------------|----------------------|
| Phase 1-2 | Global changefeed | Higher (all events to all regions) |
| Phase 3 | Regional changefeeds | Lower (only local events) |

---

## Configuration Summary by Phase

| Aspect | Phase 1 | Phase 2 | Phase 3 |
|--------|---------|---------|---------|
| **Database MR Config** | None | Enabled | Enabled |
| **account_info** | Manual PARTITION BY | REGIONAL BY ROW (computed) | REGIONAL BY ROW (computed) |
| **Other Tables** | Regular | Regular | REGIONAL BY ROW (gateway) |
| **Kafka Topics** | Global | Global | Regional |
| **Changefeeds** | 1 per table | 1 per table | 3 per table |
| **App Instances** | 3 regional | 3 regional | 3 regional |
| **UseGeoPartitioning** | false | false | true |
| **Code Changes** | N/A | **ZERO** | Config only |

---

## Deployment Checklist

### Phase 1 Deployment
- [ ] Verify database has NO multi-region config
- [ ] Deploy schema with manual partitioning
- [ ] Create global Kafka topics
- [ ] Create global changefeeds
- [ ] Deploy 3 regional app instances (UseGeoPartitioning=false)
- [ ] Verify consumer group distributes Kafka partitions

### Phase 2 Deployment
- [ ] Enable multi-region on database
- [ ] Migrate account_info to REGIONAL BY ROW (computed)
- [ ] Verify no application errors (code unchanged)
- [ ] Kafka topics still global (no changes)
- [ ] Measure performance impact

### Phase 3 Deployment
- [ ] Migrate remaining tables to REGIONAL BY ROW
- [ ] Create regional Kafka topics
- [ ] Drop global changefeeds
- [ ] Create regional changefeeds (3 per table)
- [ ] Update app configs (UseGeoPartitioning=true, regional topics)
- [ ] Restart apps with new configs
- [ ] Verify each instance consumes only regional topic
- [ ] Measure performance improvement

---

## Monitoring and Metrics

Track these metrics at each phase:

**Throughput**:
- Inserts/sec per table
- CDC events/sec
- Kafka messages/sec

**Latency**:
- Write latency (p50, p95, p99)
- Read latency (p50, p95, p99)
- CDC lag

**Resource Utilization**:
- CPU per node
- Memory per node
- Network bytes (especially cross-region)

**Errors**:
- Failed transactions
- Retry errors
- Consumer lag
- CDC failures

Use [query-analysis](https://github.com/roachlong/query-analysis) to capture persistent metrics for comparison across phases.

---

## Conclusion

This architecture demonstrates:

- ✅ **Progressive migration**: Start simple, migrate incrementally
- ✅ **Consistent app footprint**: Same 3 regional instances across all phases
- ✅ **Hybrid strategy**: Computed region for reference data, gateway region for transactional
- ✅ **Zero code changes**: Only database schema and configs evolve
- ✅ **Performance measurement**: Metrics at each phase for quantitative comparison
- ✅ **Production-ready**: Patterns proven in real-world multi-region deployments

The final hybrid approach provides the best of both worlds:
- Deterministic placement for account_info (no cross-region PK checks)
- Simplified management via multi-region abstractions
- Auto-homing for transactional data
- Follower reads for analytics (3x capacity)
