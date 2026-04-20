# Multi-Region Event-Driven Architecture

## Overview
This workload demonstrates a hybrid approach to geo-partitioning in CockroachDB:
1. **Smart client partitioning** for batch-loaded data with pre-assigned UUIDs
2. **Multi-region abstractions** (REGIONAL BY ROW) for transactional data auto-homing via gateway locality

## Architecture Flow

```
┌──────────────────────────────────────────────────────────────┐
│ 1. AccountBatchLoader (locality-aware, runs periodically)    │
│    ├─ Computes locality: crc32ieee(account_id) mod 30       │
│    ├─ Maps to region: 0-9=east, 10-19=central, 20-29=west   │
│    └─ Writes to account_info (COMPUTED locality + region)    │
└──────────────────────────────────────────────────────────────┘
                     ↓ (keyset pagination, locality-filtered)
┌──────────────────────────────────────────────────────────────┐
│ 2. RequestGenerator (3 instances, one per region)            │
│    ├─ Connects via regional LTM → PgBouncer → Gateway       │
│    ├─ Reads account_info WHERE locality IN (region buckets) │
│    ├─ Creates request_info (REGIONAL BY ROW, auto-homes)    │
│    ├─ Creates request_account_link                           │
│    └─ Inserts request_event_log → triggers CDC               │
└──────────────────────────────────────────────────────────────┘
         ↓ CDC (3 changefeeds per table, filtered by crdb_region)
┌──────────────────────────────────────────────────────────────┐
│ Kafka Topics (partitioned by account_id within region)       │
│  ├─ request-events.us-east (24 partitions)                   │
│  ├─ request-events.us-central (24 partitions)                │
│  └─ request-events.us-west (24 partitions)                   │
└──────────────────────────────────────────────────────────────┘
         ↓ (consumed by regional instances)
┌──────────────────────────────────────────────────────────────┐
│ 3. WorkflowProcessor (3 instances, one per region)           │
│    ├─ Consumes from regional topic only                      │
│    ├─ Processes workflow step, updates status                │
│    ├─ Writes to request_event_log (stays in same region)     │
│    ├─ Trigger updates request_status_head                    │
│    └─ Manual StoreOffset() + auto-commit pattern             │
└──────────────────────────────────────────────────────────────┘
         ↓ (monitors completed requests)
┌──────────────────────────────────────────────────────────────┐
│ 4. TradeGenerator (3 instances, one per region)              │
│    ├─ Reads request_status_head (terminal statuses)          │
│    ├─ Maintains active account list                          │
│    ├─ Generates random trades for primary + linked accounts  │
│    └─ Writes to trade_info (REGIONAL BY ROW, auto-homes)     │
└──────────────────────────────────────────────────────────────┘
         ↓ (cross-region analytics via global execution)
┌──────────────────────────────────────────────────────────────┐
│ 5. AnalyticsAggregator (single global instance)              │
│    ├─ Parallel paginated queries across all localities       │
│    ├─ Joins account_info + trade_info                        │
│    ├─ Aggregates by account/strategy/symbol/region           │
│    └─ Uses Task.WhenAll for concurrent page fetching         │
└──────────────────────────────────────────────────────────────┘
```

## Key Design Patterns

### 1. Hybrid Locality Strategy

**account_info (computed locality)**:
- Uses computed column: `locality INT2 AS (mod(crc32ieee(account_id::BYTES), 30))`
- Requires client to compute hash and provide locality on insert
- Avoids cross-region UUID existence checks during batch load
- Gateway location doesn't matter for this table

**All other tables (REGIONAL BY ROW)**:
- No locality column, uses CockroachDB's automatic `crdb_region` column
- Data homes to the region of the gateway used for INSERT
- Requires regional connection string per app instance
- Simpler schema, leverages multi-region abstractions

### 2. Regional App Deployment

Each transactional app (RequestGenerator, WorkflowProcessor, TradeGenerator) is deployed **3 times**:
- Instance 1: us-east config → LTM VIP (us-east) → PgBouncer (us-east) → CRDB Gateway (us-east)
- Instance 2: us-central config → LTM VIP (us-central) → PgBouncer (us-central) → CRDB Gateway (us-central)
- Instance 3: us-west config → LTM VIP (us-west) → PgBouncer (us-west) → CRDB Gateway (us-west)

**Critical**: Each instance must:
1. Use its regional connection string (from appsettings.{region}.json)
2. Only read accounts matching its locality buckets
3. Subscribe to its regional Kafka topic only
4. Write through its regional gateway to ensure auto-homing

### 3. CDC Configuration Pattern

For each table that needs CDC (request_event_log, trade_info, etc.), create **3 changefeeds**:

```sql
-- us-east changefeed (using CDC queries for regional filtering)
CREATE CHANGEFEED
INTO 'kafka://kafka:9093?topic_name=request-events.us-east'
WITH
  initial_scan = 'no',
  key_column = 'request_id',
  kafka_sink_config = '{"RequiredAcks": "ONE"}',
  cursor = 'now()'
AS SELECT request_id, seq_num, action_state_link_id, status_id, 
          event_ts, actor, metadata, idempotency_key, crdb_region
FROM request_event_log
WHERE crdb_region = 'us-east';

-- Repeat for us-central and us-west
```

**Topic partitioning**: Kafka partitions by `request_id` (or `account_id`) within each regional topic to guarantee:
- ✅ Event ordering per request/account
- ✅ Parallelism across accounts (24 partitions per topic)

### 4. Kafka Consumer Pattern (Manual Offset Store + Auto Commit)

Based on best practices from TradeCapture example:

```csharp
var config = new ConsumerConfig
{
    BootstrapServers = kafkaBootstrap,
    GroupId = $"workflow-processor-{region}",
    AutoOffsetReset = AutoOffsetReset.Earliest,
    EnableAutoCommit = true,           // Kafka auto-commits stored offsets
    EnableAutoOffsetStore = false      // Manual control of when to store
};

using var consumer = new ConsumerBuilder<string, string>(config).Build();
consumer.Subscribe(regionalTopic);

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

**Why this pattern**:
- ✅ `StoreOffset()` after successful processing marks the message ready to commit
- ✅ Kafka's auto-commit batches and commits efficiently on interval
- ✅ If processing fails before `StoreOffset()`, the offset isn't advanced
- ✅ Cleaner than manual `Commit()` calls and better error handling
- ✅ Allows replay from last successfully processed offset

### 5. Keyset Pagination Pattern

All apps reading large datasets use keyset pagination (NOT offset-based):

```csharp
// Example: RequestGenerator reading accounts
public async Task<List<AccountInfo>> GetNextPageAsync(
    short[] localityBuckets,
    int pageSize,
    (short? lastLocality, Guid? lastAccountId) cursor)
{
    var query = _dbContext.AccountInfos
        .Where(a => localityBuckets.Contains(a.Locality));
    
    if (cursor.lastLocality.HasValue && cursor.lastAccountId.HasValue)
    {
        // Keyset: WHERE (locality, account_id) > (lastLocality, lastAccountId)
        query = query.Where(a => 
            a.Locality > cursor.lastLocality.Value ||
            (a.Locality == cursor.lastLocality.Value && 
             a.AccountId > cursor.lastAccountId.Value));
    }
    
    return await query
        .OrderBy(a => a.Locality)
        .ThenBy(a => a.AccountId)
        .Take(pageSize)
        .ToListAsync();
}
```

For cross-region analytics, fetch pages in parallel:

```csharp
// AnalyticsAggregator: parallel page fetch across all localities
var pageTasks = new List<Task<List<AccountInfo>>>();

foreach (var bucket in Enumerable.Range(0, 30))
{
    pageTasks.Add(repository.GetPageAsync(
        localityBuckets: new[] { (short)bucket },
        pageSize: 1000
    ));
}

var allPages = await Task.WhenAll(pageTasks);
var allAccounts = allPages.SelectMany(p => p).ToList();
```

### 6. Trigger for request_status_head

To keep the status head table in sync with the event log:

```sql
CREATE OR REPLACE FUNCTION update_request_status_head()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO request_status_head (
        request_id,
        action_state_link_id,
        status_id,
        event_ts,
        seq_num
    )
    VALUES (
        NEW.request_id,
        NEW.action_state_link_id,
        NEW.status_id,
        NEW.event_ts,
        NEW.seq_num
    )
    ON CONFLICT (request_id) DO UPDATE SET
        action_state_link_id = EXCLUDED.action_state_link_id,
        status_id = EXCLUDED.status_id,
        event_ts = EXCLUDED.event_ts,
        seq_num = EXCLUDED.seq_num
    WHERE EXCLUDED.seq_num > request_status_head.seq_num;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_status_head
    AFTER INSERT ON request_event_log
    FOR EACH ROW
    EXECUTE FUNCTION update_request_status_head();
```

## Configuration Requirements

### Regional Connection Strings
Each app instance needs region-specific config:

```json
// appsettings.us-east.json
{
  "ConnectionStrings": {
    "DefaultConnection": "Host=vip-us-east;Port=6543;Database=defaultdb;Username=pgb;..."
  },
  "Region": "us-east",
  "LocalityBuckets": [0,1,2,3,4,5,6,7,8,9],
  "Kafka": {
    "BootstrapServers": "kafka:9093",
    "Topic": "request-events.us-east"
  }
}
```

### Kafka Consumer Groups
- WorkflowProcessor → `workflow-processor-{region}` (separate group per region)
- TradeGenerator → `trade-generator-{region}` (separate group per region)
- AnalyticsAggregator → N/A (read-only, no Kafka consumption)

## Data Locality Validation

After running the workload, use [validation-queries.sql](validation-queries.sql) to verify:

1. **Consolidated Scorecard** - Query #13 shows all alignment checks with scores (target: 100%)
2. **Leaseholder Distribution** - Queries #6-7 verify physical data placement
3. **Cross-Region Detection** - Query #9 identifies multi-region requests (expected in some cases)

Example scorecard output:
```
check_name                      | total | correct | mismatches | score_pct
--------------------------------|-------|---------|------------|----------
Request-Account Alignment       |  5000 |    5000 |          0 |    100.00
Event-Request Alignment         | 25000 |   25000 |          0 |    100.00
Trade-Account Alignment         | 50000 |   50000 |          0 |    100.00
StatusHead-Request Alignment    |  5000 |    5000 |          0 |    100.00
```

## Benefits of This Hybrid Approach

1. **Batch load performance**: Pre-computed locality avoids cross-region UUID checks
2. **Transactional simplicity**: MR abstractions handle region selection automatically
3. **Clean CDC topology**: Regional topics with no client-side filtering waste
4. **Independent scaling**: Each region's apps scale independently
5. **Data sovereignty**: All account-related data stays in account's home region
6. **Easy validation**: Clear checks with scores to prove locality alignment
7. **Reliable offset management**: Manual store + auto-commit pattern prevents data loss
