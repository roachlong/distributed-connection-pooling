# Geo-Partitioning Design: Hybrid Locality Strategy

This document explains the **hybrid geo-partitioning strategy** used in the Event Logs workload, combining manual locality partitioning with CockroachDB's multi-region abstractions.

## Table of Contents

1. [Overview](#overview)
2. [Two Approaches to Geo-Partitioning](#two-approaches-to-geo-partitioning)
3. [Design Decision: When to Use Each Approach](#design-decision-when-to-use-each-approach)
4. [Implementation Details](#implementation-details)
5. [Key Differences](#key-differences)
6. [Performance Implications](#performance-implications)
7. [Best Practices](#best-practices)

## Overview

The workload demonstrates a **hybrid strategy** that uses different geo-partitioning approaches for different tables:

| Table | Partitioning Strategy | UUID Generation | Region Assignment |
|-------|----------------------|-----------------|-------------------|
| `account_info` | **Computed Locality** | Client-side (`gen_random_uuid()`) | Hash-based: `crc32ieee(account_id) % 30` |
| `request_info` | **REGIONAL BY ROW** | CockroachDB (`gen_random_uuid()`) | Auto-homed to gateway region |
| `request_event_log` | **REGIONAL BY ROW** | CockroachDB (`gen_random_uuid()`) | Auto-homed to gateway region |
| `trade_info` | **REGIONAL BY ROW** | CockroachDB (`gen_random_uuid()`) | Auto-homed to gateway region |
| `request_status_head` | **REGIONAL BY ROW** | Inherited from `request_info` | Follows request region |

**Why hybrid?** Each approach solves different problems:
- **Computed locality**: Control data placement for batch-loaded immutable data
- **REGIONAL BY ROW**: Auto-home transactional data based on where writes originate

## Two Approaches to Geo-Partitioning

### Approach 1: Computed Locality (Manual Partitioning)

**Use Case**: `account_info` - batch-loaded account master data

**Schema**:
```sql
CREATE TABLE account_info (
    account_id UUID PRIMARY KEY,
    account_number TEXT UNIQUE NOT NULL,
    account_name TEXT NOT NULL,
    strategy TEXT,
    base_currency TEXT NOT NULL,
    locality INT NOT NULL AS (crc32ieee(account_id) % 30) STORED,
    crdb_region crdb_internal_region AS (
        CASE 
            WHEN locality BETWEEN 0 AND 9 THEN 'us-east'
            WHEN locality BETWEEN 10 AND 19 THEN 'us-central'
            ELSE 'us-west'
        END
    ) STORED,
    INDEX idx_locality (locality) PARTITION BY LIST (locality) (
        PARTITION us_east VALUES IN (0,1,2,3,4,5,6,7,8,9),
        PARTITION us_central VALUES IN (10,11,12,13,14,15,16,17,18,19),
        PARTITION us_west VALUES IN (20,21,22,23,24,25,26,27,28,29)
    ),
    INDEX idx_account_number (account_number),
    FAMILY primary_fam (account_id, account_number, account_name, strategy, base_currency, locality, crdb_region)
) PARTITION BY LIST (locality) (
    PARTITION us_east VALUES IN (0,1,2,3,4,5,6,7,8,9),
    PARTITION us_central VALUES IN (10,11,12,13,14,15,16,17,18,19),
    PARTITION us_west VALUES IN (20,21,22,23,24,25,26,27,28,29)
);

ALTER PARTITION us_east OF INDEX account_info@idx_locality 
    CONFIGURE ZONE USING constraints = '[+region=us-east]';
ALTER PARTITION us_central OF INDEX account_info@idx_locality 
    CONFIGURE ZONE USING constraints = '[+region=us-central]';
ALTER PARTITION us_west OF INDEX account_info@idx_locality 
    CONFIGURE ZONE USING constraints = '[+region=us-west]';
```

**How it works**:
1. **Client generates UUID** using `gen_random_uuid()` before INSERT
2. **Computed column** `locality = crc32ieee(account_id) % 30` creates 30 buckets (0-29)
3. **Computed column** `crdb_region` maps locality to region (0-9 → us-east, 10-19 → us-central, 20-29 → us-west)
4. **Manual partitions** pin each locality range to its home region via zone configs
5. **Application knows** which locality values belong to which region:
   ```csharp
   // Environment configuration
   LOCALITIES_US_EAST=[0,1,2,3,4,5,6,7,8,9]
   LOCALITIES_US_CENTRAL=[10,11,12,13,14,15,16,17,18,19]
   LOCALITIES_US_WEST=[20,21,22,23,24,25,26,27,28,29]
   ```

**Data flow**:
```
AccountBatchLoader (any region):
1. Generate UUID: account_id = Guid.NewGuid()
2. Compute locality = crc32(account_id) % 30  (e.g., 7)
3. INSERT with explicit account_id
4. CockroachDB routes to us-east (locality 7 is in 0-9 range)
5. Data stored in us-east region
```

**Querying**:
```csharp
// Regional RequestGenerator knows its localities
var usEastLocalities = new[] { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };

// Query only accounts in this region's locality range
var accounts = await context.AccountInfo
    .Where(a => usEastLocalities.Contains(a.Locality))
    .ToListAsync();
```

**Advantages**:
- ✅ **Deterministic placement**: You control exactly which accounts go to which region
- ✅ **Batch load efficiency**: Can insert 10,000 accounts in one batch, all land in correct region
- ✅ **Portable UUIDs**: Client-generated UUIDs work across any database
- ✅ **Explicit locality**: Easy to query "all accounts in us-east"

**Disadvantages**:
- ❌ **Manual maintenance**: Must maintain partition list and zone configs
- ❌ **Client complexity**: Application must understand locality mapping
- ❌ **Limited to static data**: Not suitable for data where region changes based on transaction origin

---

### Approach 2: REGIONAL BY ROW (Multi-Region Abstractions)

**Use Case**: `request_info`, `request_event_log`, `trade_info` - transactional data

**Schema**:
```sql
CREATE TABLE request_info (
    request_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_type_id INT NOT NULL REFERENCES request_type(request_type_id),
    primary_account_id UUID NOT NULL REFERENCES account_info(account_id),
    requested_by TEXT NOT NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT current_timestamp(),
    request_status_id INT NOT NULL REFERENCES request_status(status_id),
    crdb_region crdb_internal_region NOT NULL DEFAULT gateway_region()::crdb_internal_region
) LOCALITY REGIONAL BY ROW AS crdb_region;
```

**How it works**:
1. **CockroachDB generates UUID** via `DEFAULT gen_random_uuid()` - no client involvement
2. **Gateway region assignment** via `DEFAULT gateway_region()::crdb_internal_region`
3. **Auto-homing**: Row's `crdb_region` column is set to the region of the gateway node that processed the INSERT
4. **No manual partitions**: CockroachDB handles placement automatically

**Data flow**:
```
RequestGenerator (us-east instance):
1. Connect to us-east gateway (via regional PgBouncer VIP 172.18.0.251)
2. INSERT without specifying request_id or crdb_region
3. Gateway generates UUID and sets crdb_region = 'us-east'
4. Data stored in us-east region
5. Foreign key to account_info works even if account is in different region
```

**Querying**:
```csharp
// Implicit locality - gateway region determines which data you see locally
var requests = await context.RequestInfo
    .Where(r => r.RequestedBy == "system-us-east")
    .ToListAsync();  // Fast if run from us-east gateway

// Explicit cross-region query
var allRequests = await context.RequestInfo
    .AsNoTracking()
    .ToListAsync();  // May involve cross-region reads
```

**Follower reads** for analytics:
```sql
-- Query local region data with follower reads (any replica)
SELECT *
FROM request_info
AS OF SYSTEM TIME follower_read_timestamp()
WHERE crdb_region = 'us-east'
```

**Advantages**:
- ✅ **Zero client complexity**: App doesn't need to know anything about regions or locality
- ✅ **Auto-homing**: Data automatically goes to the region where transaction originates
- ✅ **Dynamic placement**: Works for data where "home region" depends on transaction origin
- ✅ **Simpler schema**: No manual partitions or zone configs
- ✅ **Foreign keys work**: Can reference rows in other regions (e.g., request → account)

**Disadvantages**:
- ❌ **Gateway dependency**: Region assignment depends on which gateway processes the write
- ❌ **No deterministic placement**: Can't guarantee a specific row goes to a specific region
- ❌ **CockroachDB-specific UUIDs**: UUIDs generated by CockroachDB, not portable

---

## Design Decision: When to Use Each Approach

### Use Computed Locality When:

1. **Batch-loaded immutable data**
   - Example: Account master data loaded once, rarely updated
   - Benefit: Control placement of entire batch upfront

2. **Client controls keys**
   - Example: Account IDs generated by external system
   - Benefit: Use existing UUIDs, compute locality at load time

3. **Need explicit region queries**
   - Example: "Give me all accounts in us-east" without filtering on crdb_region
   - Benefit: Query by locality value (0-9) instead of region enum

4. **Workload doesn't require cross-region foreign keys**
   - Example: Account data is self-contained
   - Benefit: Simpler constraint model

### Use REGIONAL BY ROW When:

1. **Transactional data with clear "origin region"**
   - Example: Requests created by regional application instances
   - Benefit: Data automatically homes where transaction originates

2. **Foreign keys to reference data**
   - Example: Requests reference accounts (possibly in different regions)
   - Benefit: CockroachDB handles cross-region FK checks

3. **Dynamic region assignment**
   - Example: Request can be created from any region depending on user location
   - Benefit: No need to pre-compute or hard-code region assignment

4. **Simplified application logic**
   - Example: App doesn't want to know about locality or region mapping
   - Benefit: CockroachDB handles everything automatically

---

## Implementation Details

### Account Loading (Computed Locality)

```csharp
// EventLogs.AccountBatchLoader
public async Task LoadAccountsAsync()
{
    var accounts = new List<AccountInfo>();
    
    for (int i = 0; i < totalAccounts; i++)
    {
        var accountId = Guid.NewGuid();
        var locality = CRC32.ComputeLocalityHash(accountId.ToString(), 30);
        
        accounts.Add(new AccountInfo
        {
            AccountId = accountId,  // Client-generated
            AccountNumber = $"ACCT-{i:D8}",
            AccountName = $"Account {i}",
            Strategy = RandomStrategy(),
            BaseCurrency = "USD"
            // locality and crdb_region computed automatically
        });
    }
    
    // Batch insert - CockroachDB routes each row to correct region
    await context.AccountInfo.AddRangeAsync(accounts);
    await context.SaveChangesAsync();
}
```

### Request Generation (REGIONAL BY ROW)

```csharp
// EventLogs.RequestGenerator (us-east instance)
public async Task GenerateRequestsAsync()
{
    // Query only accounts in this region's locality range
    var localAccounts = await context.AccountInfo
        .Where(a => usEastLocalities.Contains(a.Locality))
        .ToListAsync();
    
    foreach (var account in localAccounts)
    {
        var request = new RequestInfo
        {
            // No RequestId - CockroachDB generates it
            // No CrdbRegion - gateway sets to 'us-east'
            RequestTypeId = requestTypeId,
            PrimaryAccountId = account.AccountId,  // FK to account (any region)
            RequestedBy = "system-us-east",
            RequestStatusId = initialStatusId
        };
        
        context.RequestInfo.Add(request);
    }
    
    await context.SaveChangesAsync();
    // All requests auto-homed to us-east because gateway is us-east
}
```

### Relationship Between Tables

```
account_info (computed locality)
    └── FK ← request_info (REGIONAL BY ROW, auto-homed to gateway region)
            └── FK ← request_event_log (REGIONAL BY ROW, follows request region)
            └── FK ← trade_info (REGIONAL BY ROW, follows request region)
```

**Key insight**: Even though `request_info.crdb_region` may differ from `account_info.crdb_region`, the foreign key works because CockroachDB can validate across regions. The RequestGenerator ensures **semantic locality** by only creating requests for accounts in its locality range, even though **physical locality** is determined by gateway region.

---

## Key Differences

| Aspect | Computed Locality | REGIONAL BY ROW |
|--------|------------------|-----------------|
| **UUID Generation** | Client-side (`Guid.NewGuid()` in C#) | Server-side (`gen_random_uuid()` in SQL) |
| **Region Assignment** | Computed from UUID hash | Gateway region at insert time |
| **Partitioning** | Manual (PARTITION BY LIST) | Automatic (LOCALITY REGIONAL BY ROW) |
| **Zone Config** | Manual (ALTER PARTITION ... CONFIGURE ZONE) | Automatic (managed by MR system) |
| **Application Awareness** | Must know locality mapping | No region awareness needed |
| **Cross-Region Queries** | Use locality filter (`WHERE locality IN (...)`) | Use crdb_region filter (`WHERE crdb_region = 'us-east'`) |
| **Data Placement** | Deterministic (based on UUID) | Dynamic (based on gateway) |
| **Foreign Keys** | Same-region only (practical) | Cross-region supported |
| **Schema Complexity** | Higher (partition lists, zone configs) | Lower (one LOCALITY clause) |
| **Portability** | Database-agnostic UUID strategy | CockroachDB-specific |

---

## Performance Implications

### Writes

**Computed Locality**:
- ✅ **Batch inserts**: Efficient - all rows in batch go to correct region
- ✅ **Single-region transactions**: If all rows hash to same region
- ❌ **Cross-region if hash mismatch**: Rare, but possible if batch has mixed localities

**REGIONAL BY ROW**:
- ✅ **Single-region transactions**: Always - all rows written via same gateway home to that gateway's region
- ✅ **No cross-region overhead**: For writes to the REGIONAL BY ROW table itself
- ⚠️ **FK validation**: May require cross-region read if referenced row is in different region

### Reads

**Computed Locality**:
- ✅ **Regional queries**: Very fast - `WHERE locality IN (0-9)` only scans us-east partitions
- ❌ **No follower reads**: Standard table, requires leaseholder reads

**REGIONAL BY ROW**:
- ✅ **Follower reads**: Use `AS OF SYSTEM TIME follower_read_timestamp()` to read from any replica (3x capacity)
- ✅ **Regional queries**: Fast - `WHERE crdb_region = 'us-east'` only scans us-east data
- ⚠️ **Cross-region joins**: If joining with computed locality table, may span regions

### Analytics

Both approaches support efficient regional analytics:

```sql
-- Computed locality approach
SELECT account_name, COUNT(*)
FROM account_info
WHERE locality BETWEEN 0 AND 9  -- us-east localities
GROUP BY account_name

-- REGIONAL BY ROW approach (with follower reads)
SELECT requested_by, COUNT(*)
FROM request_info
AS OF SYSTEM TIME follower_read_timestamp()
WHERE crdb_region = 'us-east'
GROUP BY requested_by
```

The REGIONAL BY ROW approach has an advantage for analytics: follower reads distribute load across all replicas.

---

## Best Practices

### 1. Use Hybrid Strategy

Don't force one approach everywhere. Mix and match based on table characteristics:

```
✅ Computed locality for:
  - Account master data
  - Customer profiles
  - Product catalogs
  - Reference data loaded via ETL

✅ REGIONAL BY ROW for:
  - Orders, requests, transactions
  - Event logs, audit trails
  - User-generated content
  - Time-series data
```

### 2. Align Application Deployment with Data Locality

**Computed locality**: Deploy regional instances that query their locality range
```csharp
// us-east instance
var usEastLocalities = config["Localities_us_east"];  // [0,1,2,3,4,5,6,7,8,9]
var accounts = context.AccountInfo
    .Where(a => usEastLocalities.Contains(a.Locality));
```

**REGIONAL BY ROW**: Deploy regional instances that connect to regional gateway
```csharp
// us-east instance connects to us-east VIP
ConnectionString = "Host=172.18.0.251;Port=5432;..."
// All inserts auto-home to us-east
```

### 3. Use Follower Reads for Analytics

For REGIONAL BY ROW tables, always use follower reads in analytics queries:

```csharp
// ✅ Good - uses follower reads
var stats = await context.RequestInfo
    .FromSqlRaw(@"
        SELECT *
        FROM request_info
        AS OF SYSTEM TIME follower_read_timestamp()
        WHERE crdb_region = {0}
    ", region)
    .ToListAsync();

// ❌ Bad - forces leaseholder reads
var stats = await context.RequestInfo
    .Where(r => r.CrdbRegion == region)
    .ToListAsync();
```

### 4. Document Locality Mapping

For computed locality approach, document the mapping clearly:

```bash
# .env file
LOCALITIES_US_EAST=[0,1,2,3,4,5,6,7,8,9]
LOCALITIES_US_CENTRAL=[10,11,12,13,14,15,16,17,18,19]
LOCALITIES_US_WEST=[20,21,22,23,24,25,26,27,28,29]
```

Update this when adding/removing regions.

### 5. Validate Data Locality Alignment

Run validation queries to ensure data landed in correct regions:

```sql
-- For computed locality tables
SELECT 
    CASE 
        WHEN locality BETWEEN 0 AND 9 THEN 'us-east'
        WHEN locality BETWEEN 10 AND 19 THEN 'us-central'
        ELSE 'us-west'
    END AS expected_region,
    crdb_region AS actual_region,
    COUNT(*)
FROM account_info
GROUP BY expected_region, actual_region

-- For REGIONAL BY ROW tables
SELECT 
    ai.crdb_region AS account_region,
    ri.crdb_region AS request_region,
    COUNT(*)
FROM request_info ri
JOIN account_info ai ON ri.primary_account_id = ai.account_id
GROUP BY account_region, request_region
```

Expected: All rows should have `expected_region = actual_region`.

### 6. Consider Hybrid Foreign Keys

It's OK to have foreign keys from REGIONAL BY ROW tables to computed locality tables:

```sql
-- request_info (REGIONAL BY ROW) → account_info (computed locality)
-- Request might be in us-east, account might be in us-central
-- CockroachDB validates FK across regions automatically
```

This is acceptable because:
- Reads are usually co-located (regional RequestGenerator only creates requests for local accounts)
- Writes can tolerate occasional cross-region FK validation overhead
- Allows flexibility in request origin (user in us-east can create request for account homed in us-central)

---

## Conclusion

The **hybrid geo-partitioning strategy** combines the best of both worlds:

- **Computed locality** for control and batch efficiency on reference data
- **REGIONAL BY ROW** for simplicity and auto-homing on transactional data

This approach provides:
- ✅ Predictable data placement for master data
- ✅ Automatic homing for transactional data
- ✅ Efficient regional queries for both types
- ✅ Foreign key relationships across partitioning strategies
- ✅ Follower reads for analytics on transactional tables
- ✅ Clear separation of concerns: batch-load vs real-time transactions

When designing your own multi-region application, consider which tables fit each pattern and don't be afraid to mix approaches.
