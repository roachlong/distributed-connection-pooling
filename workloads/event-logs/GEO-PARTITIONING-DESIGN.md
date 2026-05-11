# Geo-Partitioning Design: Hybrid Strategy with Migration Path

This document explains the **hybrid geo-partitioning strategy** used in the Event Logs workload, demonstrating a progressive migration from manual partitioning to CockroachDB's multi-region abstractions.

## Table of Contents

1. [Overview](#overview)
2. [Migration Path: Three Phases](#migration-path-three-phases)
3. [Two Approaches to Geo-Partitioning](#two-approaches-to-geo-partitioning)
4. [Design Decision: When to Use Each Approach](#design-decision-when-to-use-each-approach)
5. [Implementation Details](#implementation-details)
6. [Key Differences](#key-differences)
7. [Performance Implications](#performance-implications)
8. [Best Practices](#best-practices)

## Overview

This workload demonstrates **progressive adoption** of multi-region abstractions with a final **hybrid strategy**:

**Final State (Phase 3 - Hybrid Strategy)**:

| Table | Partitioning Strategy | Primary Key | Region Assignment |
|-------|----------------------|-------------|-------------------|
| `account_info` | **REGIONAL BY ROW** (computed region) | `(locality, account_number)` | Computed from account_number hash |
| `request_info` | **REGIONAL BY ROW** (gateway region) | `request_id` | Auto-set by gateway |
| `request_event_log` | **REGIONAL BY ROW** (gateway region) | `(request_id, seq_num)` | Auto-set by gateway |
| `trade_info` | **REGIONAL BY ROW** (gateway region) | `trade_id` | Auto-set by gateway |
| `request_status_head` | **REGIONAL BY ROW** (gateway region) | `request_id` | Auto-set by gateway |

**Why hybrid?**
- **account_info**: Computed region from business key → deterministic placement, no cross-region PK checks
- **Other tables**: Gateway region → dynamic placement, CRDB-generated UUIDs

**Why progressive migration?**
- Start simple with manual partitioning (no multi-region database)
- Enable multi-region and migrate tables incrementally
- Measure performance impact at each phase
- Zero application code changes throughout

---

## Migration Path: Three Phases

### Phase 1: Manual Partitioning (No Multi-Region Database)

**Database Configuration**: NO multi-region setup (required for `PARTITION BY`)

```sql
-- Database is NOT multi-region configured
SHOW REGIONS FROM DATABASE defaultdb;  -- Returns 0 rows
```

**account_info Schema**:
```sql
CREATE TABLE account_info (
    account_number  STRING NOT NULL,
    account_name    STRING NOT NULL,
    strategy        STRING NULL,
    base_currency   STRING NULL,

    -- Hash-based locality bucket [0..29] derived from account_number
    locality INT2 NOT NULL AS (
        mod(crc32ieee(account_number), 30:::INT8)::INT2
    ) STORED,

    PRIMARY KEY (locality, account_number)
) PARTITION BY LIST (locality) (
    PARTITION us_east VALUES IN ((0), (1), (2), (3), (4), (5), (6), (7), (8), (9)),
    PARTITION us_central VALUES IN ((10), (11), (12), (13), (14), (15), (16), (17), (18), (19)),
    PARTITION us_west VALUES IN ((20), (21), (22), (23), (24), (25), (26), (27), (28), (29))
);

-- Manual zone configs for regional placement
ALTER PARTITION us_east OF INDEX account_info@pk_account_info CONFIGURE ZONE USING
    num_replicas = 5,
    constraints = '{+region=us-east: 1, +region=us-central: 1, +region=us-west: 1}',
    lease_preferences = '[[+region=us-east], [+region=us-central], [+region=us-west]]';
-- (repeat for us_central and us_west partitions)
```

**Other Tables**: Regular tables, no partitioning

**Characteristics**:
- Manual zone config management
- Cannot use `REGIONAL BY ROW` (requires multi-region database)
- Deterministic placement via locality hash
- No cross-region primary key checks (locality partitions keyspace)

---

### Phase 2: Enable Multi-Region + Hybrid (account_info)

**Database Configuration**: Multi-region ENABLED

```sql
ALTER DATABASE defaultdb SET PRIMARY REGION "us-east";
ALTER DATABASE defaultdb ADD REGION "us-central";
ALTER DATABASE defaultdb ADD REGION "us-west";
ALTER DATABASE defaultdb SURVIVE REGION FAILURE;
```

**account_info Migration**: Convert to `REGIONAL BY ROW` with **computed region**

```sql
CREATE TABLE account_info (
    account_number  STRING NOT NULL,
    account_name    STRING NOT NULL,
    strategy        STRING NULL,
    base_currency   STRING NULL,
    
    -- Computed locality (still part of primary key)
    locality INT2 NOT NULL AS (
        mod(crc32ieee(account_number), 30:::INT8)::INT2
    ) STORED,
    
    -- Computed region (maps locality to region)
    computed_region crdb_internal_region NOT NULL AS (
        CASE 
            WHEN locality BETWEEN 0 AND 9 THEN 'us-east'::crdb_internal_region
            WHEN locality BETWEEN 10 AND 19 THEN 'us-central'::crdb_internal_region
            ELSE 'us-west'::crdb_internal_region
        END
    ) STORED,
    
    PRIMARY KEY (locality, account_number)
) LOCALITY REGIONAL BY ROW AS computed_region;
--                            ^^^^^^^^^^^^^^^^
--                            Uses computed column, NOT gateway_region()
```

**Key Points**:
- ✅ Still uses `(locality, account_number)` as primary key
- ✅ Both `locality` and `computed_region` are computed from `account_number`
- ✅ Client provides business key → deterministic placement
- ✅ **No cross-region primary key checks** (locality partitions the keyspace)
- ✅ No manual zone configs (CockroachDB manages via `computed_region`)
- ❌ **NOT** using `gateway_region()` - region is deterministic from hash

**Other Tables**: Still regular (not migrated yet)

**Benefits**:
- Simplified schema (no manual zone configs)
- CockroachDB auto-manages placement based on computed region
- Same deterministic placement behavior as Phase 1
- Zero application code changes

---

### Phase 3: Full Multi-Region + Regional CDC

**All Other Tables Migrated**: Use gateway-based `REGIONAL BY ROW`

```sql
-- Pure REGIONAL BY ROW (gateway-based region assignment)
CREATE TABLE request_info (
    request_id          UUID NOT NULL DEFAULT gen_random_uuid(),
    request_type_id     INT4 NOT NULL,
    primary_account_number  STRING NOT NULL,
    created_ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    requested_by        STRING NOT NULL,
    request_status_id   INT4 NOT NULL,
    
    PRIMARY KEY (request_id)
) LOCALITY REGIONAL BY ROW;
--           ^^^^^^^^^^^^^^^^^
--           Uses implicit gateway_region(), NOT computed
```

**Key Differences from account_info**:
- ❌ No locality column
- ❌ No computed region column
- ✅ `crdb_region` set by `gateway_region()` at insert time
- ✅ CockroachDB generates UUID (no client-provided key)
- ✅ Dynamic placement based on which gateway processes the write
- ⚠️ Primary key uniqueness checked within region (acceptable for UUIDs)

**Regional Changefeeds**: One per region per table

```sql
-- us-east changefeed
CREATE CHANGEFEED ... 
AS SELECT * FROM request_event_log WHERE crdb_region = 'us-east';
-- (repeat for us-central, us-west)
```

**Benefits**:
- Auto-homing for transactional data
- Regional CDC reduces cross-region traffic
- Simplified schema across all tables

---

## Two Approaches to Geo-Partitioning

### Approach 1: REGIONAL BY ROW with Computed Region (Hybrid)

**Use Case**: `account_info` - batch-loaded data with client-provided business keys

**Schema Pattern**:
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

**How it works**:
1. **Client provides** `account_number` (business key)
2. **Database computes** `locality` from hash: `crc32ieee(account_number) % 30`
3. **Database computes** `computed_region` from locality mapping
4. **Deterministic placement**: Same account_number always → same region
5. **No cross-region PK checks**: Locality partitions the keyspace

**Data flow**:
```
AccountBatchLoader (any region):
1. Generate account_number = "ACCT-00000123"
2. INSERT (account_number, account_name, ...)
   -- locality auto-computed: crc32("ACCT-00000123") % 30 = 7
   -- computed_region auto-set: 'us-east' (locality 7 is in 0-9)
3. Data stored in us-east region
4. No cross-region checks needed (locality=7 only exists in us-east)
```

**Advantages**:
- ✅ **Deterministic placement**: Hash-based, predictable
- ✅ **No cross-region PK checks**: Locality partitions keyspace
- ✅ **Client-controlled keys**: Use business-meaningful identifiers
- ✅ **Batch efficiency**: Can load large batches, all land in correct regions
- ✅ **No manual zone configs**: CockroachDB manages via computed region
- ✅ **Follower reads**: Available in Phase 2+

**Disadvantages**:
- ❌ **More complex schema**: Requires computed columns
- ❌ **Composite primary key**: `(locality, account_number)` instead of single column
- ❌ **Application awareness**: Must understand locality exists (even if not queried)

---

### Approach 2: REGIONAL BY ROW with Gateway Region (Pure)

**Use Case**: Transactional data where origin region determines placement

**Schema Pattern**:
```sql
CREATE TABLE request_info (
    request_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    primary_account_number STRING NOT NULL,
    ...
) LOCALITY REGIONAL BY ROW;
```

**How it works**:
1. **CockroachDB generates UUID** via `gen_random_uuid()`
2. **Gateway sets region** via implicit `gateway_region()` function
3. **Dynamic placement**: Data homes to gateway that processed the INSERT
4. **No computed columns**: Pure multi-region abstraction

**Data flow**:
```
RequestGenerator (us-east instance):
1. Connect to us-east gateway
2. INSERT (primary_account_number, requested_by, ...)
   -- request_id auto-generated: CockroachDB creates UUID
   -- crdb_region auto-set: 'us-east' (from gateway_region())
3. Data stored in us-east region
4. UUID uniqueness checked within us-east only (acceptable collision risk)
```

**Advantages**:
- ✅ **Zero client complexity**: No locality, no computed columns
- ✅ **Simple primary key**: Single UUID column
- ✅ **Auto-homing**: Data lands where transaction originates
- ✅ **Clean schema**: Minimal SQL, pure multi-region abstraction
- ✅ **Foreign keys work**: Can reference rows in other regions

**Disadvantages**:
- ❌ **Gateway dependency**: Placement depends on which gateway used
- ❌ **Non-deterministic**: Same logical operation could land in different regions
- ❌ **CRDB-generated UUIDs**: Less portable across databases

---

## Design Decision: When to Use Each Approach

### Use Computed Region (Hybrid) When:

1. **Client provides the business key**
   - Account numbers, customer IDs, order numbers
   - Keys generated by external systems
   - Need deterministic placement based on business key

2. **Batch-loaded immutable data**
   - Account master data loaded once
   - Product catalogs, pricing tables
   - Reference data from ETL pipelines

3. **Need to avoid cross-region PK checks**
   - High-volume inserts
   - Want guaranteed single-region transactions
   - Locality-based key partitioning eliminates cross-region validation

4. **Deterministic placement is critical**
   - Regulatory requirements (data must be in specific region)
   - Testing scenarios (need repeatable placement)
   - Want to control exactly which records go where

### Use Gateway Region (Pure) When:

1. **CRDB generates the primary key**
   - Request IDs, event IDs, transaction IDs
   - No external key source
   - UUIDs work fine

2. **Transactional data with origin region**
   - Requests created by regional app instances
   - Events, audit logs, time-series data
   - Data homes naturally where transaction started

3. **Want simplest schema**
   - No computed columns
   - No composite keys
   - Pure multi-region abstraction

4. **Foreign keys to reference data**
   - Requests reference accounts (possibly different regions)
   - CockroachDB handles cross-region FK checks
   - Acceptable FK validation overhead

---

## Implementation Details

### Phase 1: Manual Partitioning

**Account Loading**:
```csharp
// EventLogs.AccountBatchLoader
public async Task LoadAccountsAsync()
{
    var batch = new List<AccountInfo>();
    
    for (int i = 0; i < batchSize; i++)
    {
        var accountNumber = $"ACCT-{totalLoaded + i:D8}";
        
        // Optional: Compute locality for metrics/routing
        // (Database will compute it anyway)
        var locality = LocalityHasher.ComputeLocality(accountNumber);
        var region = LocalityHasher.LocalityToRegion(locality);
        
        batch.Add(new AccountInfo
        {
            AccountNumber = accountNumber,
            AccountName = $"Account {i}",
            Strategy = strategies[random.Next(strategies.Length)],
            BaseCurrency = "USD"
            // locality auto-computed by database
        });
    }
    
    await context.AccountInfo.AddRangeAsync(batch);
    await context.SaveChangesAsync();
}
```

---

### Phase 2+: Hybrid (account_info) + Pure (other tables)

**Account Loading** (same code as Phase 1):
```csharp
// No code changes from Phase 1!
public async Task LoadAccountsAsync()
{
    var batch = new List<AccountInfo>();
    
    for (int i = 0; i < batchSize; i++)
    {
        batch.Add(new AccountInfo
        {
            AccountNumber = $"ACCT-{totalLoaded + i:D8}",
            AccountName = $"Account {i}",
            Strategy = strategies[random.Next(strategies.Length)],
            BaseCurrency = "USD"
            // locality + computed_region auto-computed
        });
    }
    
    await context.AccountInfo.AddRangeAsync(batch);
    await context.SaveChangesAsync();
}
```

**Request Generation** (gateway-based placement):
```csharp
// EventLogs.RequestGenerator (us-east instance)
public async Task GenerateRequestsAsync()
{
    var accounts = await context.AccountInfo
        .Take(100)
        .ToListAsync();
    
    foreach (var account in accounts)
    {
        var request = new RequestInfo
        {
            // No RequestId - CockroachDB generates UUID
            // No CrdbRegion - gateway sets to 'us-east'
            RequestTypeId = requestTypeId,
            PrimaryAccountNumber = account.AccountNumber,
            RequestedBy = "system-us-east",
            RequestStatusId = initialStatusId
        };
        
        context.RequestInfo.Add(request);
    }
    
    await context.SaveChangesAsync();
    // All requests auto-homed to us-east via gateway_region()
}
```

---

## Key Differences

| Aspect | Computed Region (Hybrid) | Gateway Region (Pure) |
|--------|--------------------------|----------------------|
| **Example Table** | `account_info` | `request_info`, `trade_info` |
| **Primary Key** | `(locality, account_number)` | `request_id` (UUID) |
| **Key Provider** | Client | CockroachDB |
| **Locality Column** | ✅ Computed from business key | ❌ Not present |
| **Region Column** | `computed_region` (computed) | `crdb_region` (from gateway) |
| **Region Assignment** | Hash-based, deterministic | Gateway-based, dynamic |
| **Cross-Region PK Checks** | ❌ Not needed (locality partitions) | ⚠️ Within region only |
| **Placement Control** | ✅ Fully deterministic | ❌ Depends on gateway |
| **Schema Complexity** | Higher (computed columns) | Lower (pure MR abstraction) |
| **Use Case** | Batch-loaded reference data | Transactional data |

---

## Performance Implications

### Writes

**Computed Region (account_info)**:
- ✅ **No cross-region PK checks**: Locality partitions keyspace
- ✅ **Deterministic routing**: App knows which gateway to use
- ✅ **Batch efficiency**: Large batches, all land correctly
- ✅ **Single-region transactions**: Guaranteed

**Gateway Region (request_info, etc.)**:
- ✅ **Single-region writes**: Data lands at gateway region
- ✅ **Simple inserts**: No locality computation needed
- ⚠️ **FK validation**: May cross regions (e.g., request → account)
- ⚠️ **UUID uniqueness**: Checked within region (acceptable risk)

### Reads

**Both Approaches** (Phase 2+):
- ✅ **Follower reads**: `AS OF SYSTEM TIME follower_read_timestamp()`
- ✅ **Regional scans**: Filter by `crdb_region` or locality
- ✅ **Reduced leaseholder contention**: Read from any replica

**Computed Region**:
```sql
-- Query by computed_region (acts like crdb_region)
SELECT * FROM account_info
AS OF SYSTEM TIME follower_read_timestamp()
WHERE computed_region = 'us-east';
```

**Gateway Region**:
```sql
-- Query by crdb_region
SELECT * FROM request_info
AS OF SYSTEM TIME follower_read_timestamp()
WHERE crdb_region = 'us-east';
```

### Cross-Region Operations

**Computed Region → Gateway Region FK**:
```sql
-- request_info references account_info
-- Request in us-east, account in us-central (possible)
-- CockroachDB validates FK across regions (tolerable overhead)
```

This is acceptable because:
- FK checks are infrequent (only on INSERT/UPDATE)
- Most requests reference local accounts (semantic locality)
- Benefit of flexibility outweighs occasional cross-region check

---

## Best Practices

### 1. Use Hybrid Strategy for the Right Reasons

```
✅ Computed Region (account_info) when:
  - Client provides business key
  - Need deterministic placement
  - Want to avoid cross-region PK checks
  - Batch-loaded reference data

✅ Gateway Region (request_info, trade_info) when:
  - CRDB generates primary key (UUID)
  - Transactional data with origin region
  - Want simplest schema
  - Foreign keys to reference data
```

### 2. Understand Primary Key Partitioning

**Computed Region** (no cross-region checks):
```sql
PRIMARY KEY (locality, account_number)
-- locality 7, account "ACCT-00000123" → only exists in us-east
-- locality 15, account "ACCT-00000456" → only exists in us-central
-- No overlap, no cross-region PK validation needed
```

**Gateway Region** (within-region checks):
```sql
PRIMARY KEY (request_id)
-- UUID collision probability is negligible
-- CRDB only checks uniqueness within the region
-- Acceptable risk for distributed systems
```

### 3. Use Business Keys for account_info

```sql
-- ✅ Good - business-meaningful, stable hash
account_number STRING  -- "ACCT-00000123"

-- ❌ Avoid - opaque UUID, no business meaning
account_id UUID
```

### 4. Maintain Consistent Application Architecture

Keep the same app footprint across all phases:
```
Phase 1: 3 regional instances → manual partitioning
Phase 2: 3 regional instances → hybrid (account_info migrated)
Phase 3: 3 regional instances → all tables migrated

Only database schema changes, not application.
```

### 5. Use Follower Reads in Analytics (Phase 2+)

```csharp
// ✅ Good - follower reads (3x capacity)
var stats = await context.AccountInfo
    .FromSqlRaw(@"
        SELECT *
        FROM account_info
        AS OF SYSTEM TIME follower_read_timestamp()
        WHERE computed_region = {0}
    ", region)
    .ToListAsync();
```

### 6. Document Locality Mapping

```csharp
// LocalityHasher.cs
public static string LocalityToRegion(short locality)
{
    return locality switch
    {
        >= 0 and <= 9 => "us-east",
        >= 10 and <= 19 => "us-central",
        >= 20 and <= 29 => "us-west",
        _ => throw new ArgumentOutOfRangeException()
    };
}
```

### 7. Measure Performance at Each Phase

Track metrics for each migration phase:
- Query latency (p50, p95, p99)
- Throughput (inserts/sec, reads/sec)
- Cross-region traffic
- Contention events
- PK validation overhead

---

## Conclusion

The **hybrid geo-partitioning strategy** combines two REGIONAL BY ROW approaches:

1. **Computed Region** (account_info):
   - Client-provided business keys
   - Deterministic placement via hash
   - No cross-region PK checks (locality partitions keyspace)
   - Ideal for batch-loaded reference data

2. **Gateway Region** (request_info, trade_info, etc.):
   - CRDB-generated UUIDs
   - Dynamic placement via gateway
   - Simpler schema, pure multi-region abstraction
   - Ideal for transactional data

**Key Benefits**:
- ✅ Best of both worlds: control + simplicity
- ✅ No cross-region PK overhead for account_info
- ✅ Follower reads for all tables (Phase 2+)
- ✅ Progressive migration path (measure at each step)
- ✅ Zero application code changes

**Migration Path**:
1. Start simple (manual partitioning, no multi-region DB)
2. Enable multi-region, migrate account_info (hybrid)
3. Migrate other tables (pure gateway-based)
4. Add regional CDC

Choose the approach that fits your data characteristics, and don't be afraid to mix strategies within the same database.
