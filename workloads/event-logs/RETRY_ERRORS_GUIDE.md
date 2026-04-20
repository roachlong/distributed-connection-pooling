# CockroachDB Error Handling Guide

Comprehensive guide for handling CockroachDB errors in distributed applications. See [WorkflowProcessor/Program.cs](EventLogs.WorkflowProcessor/Program.cs) for complete implementation examples.

## Quick Reference

| Error Code | Type | Action |
|------------|------|--------|
| `40001` | Serialization failure | **RETRY** entire transaction with exponential backoff |
| `40003` | Ambiguous result | **VERIFY** or treat as success if idempotent |
| `08xxx` | Connection error | **RETRY** with new connection |
| `57xxx` | Server error | **RETRY** with backoff |
| `23505` | Unique violation | **IGNORE** if idempotent, else fail |

---

## Error Categories

### 40001 — Serialization Failure (SAFE TO RETRY)

**What:** Transaction conflict due to concurrent modifications or timestamp ordering issues.

**Cause:** Multiple transactions attempting to modify the same data concurrently.

**Action:** 
- Retry the **entire transaction** with exponential backoff
- Single-statement transactions are automatically retried by CRDB
- Multi-statement transactions require application-level retry loop

**Implementation:**
```csharp
var retryAttempt = 0;
const int maxRetries = 10;

while (retryAttempt < maxRetries)
{
    try
    {
        await using var transaction = await connection.BeginTransactionAsync();
        // ... perform all operations ...
        await transaction.CommitAsync();
        return; // Success
    }
    catch (PostgresException ex) when (ex.SqlState == "40001")
    {
        retryAttempt++;
        var delayMs = (int)Math.Pow(2, retryAttempt) * 100; // 100ms, 200ms, 400ms...
        logger.LogWarning("Serialization error (40001), retry {Attempt}/{Max} after {Delay}ms",
            retryAttempt, maxRetries, delayMs);
        await Task.Delay(delayMs, cancellationToken);
    }
}
```

---

### 40003 — Ambiguous Result (INDETERMINATE)

**What:** Cannot determine if COMMIT succeeded or failed (e.g., network failure during commit).

**Cause:** Connection loss or server crash after COMMIT sent but before acknowledgment received.

**Action:**
- **DO NOT** blindly retry non-idempotent operations
- Use idempotency keys or read-back verification
- For idempotent operations, treat as success

**Implementation:**
```csharp
catch (PostgresException ex) when (ex.SqlState == "40003")
{
    logger.LogWarning("Ambiguous result (40003), verifying transaction state...");
    
    // Option 1: If ALL operations are idempotent, treat as success
    // (Our workload uses idempotency keys on all inserts)
    return;
    
    // Option 2: Read back to verify (for critical operations)
    var committed = await VerifyTransactionCommitted(idempotencyKey, connection);
    if (!committed)
    {
        // Safe to retry since we verified it didn't commit
        retryAttempt++;
        continue;
    }
    return; // Already committed, treat as success
}
```

---

### 08xx & 57xx — Connection/Network Errors (TRANSIENT)

**What:** Connection failures, I/O errors, or server shutdowns.

**Examples:**
- `08001` — Connection refused
- `08003` — Connection does not exist
- `08004` — Server rejected connection
- `08006` — I/O error sending to backend
- `08007` — Transaction resolution unknown
- `08S01` — Communication link failure
- `57P01` — Server shutting down

**Cause:** Network issues, load balancer failover, node restart, connection pool exhaustion.

**Action:**
- Retry with exponential backoff
- Re-establish connection if needed
- **Warning:** Commits in flight may be ambiguous (treat like 40003)

**Implementation:**
```csharp
catch (PostgresException ex) when (ex.SqlState?.StartsWith("08") == true || 
                                     ex.SqlState?.StartsWith("57") == true)
{
    retryAttempt++;
    var delayMs = (int)Math.Pow(2, retryAttempt) * 100;
    logger.LogWarning("Connection error ({SqlState}), retry {Attempt}/{Max} after {Delay}ms",
        ex.SqlState, retryAttempt, maxRetries, delayMs);
    await Task.Delay(delayMs, cancellationToken);
    // Connection will be recreated on next attempt
}
```

---

### 23505 — Unique Violation (APPLICATION LOGIC)

**What:** Duplicate key violation on unique constraint or primary key.

**Cause:** 
- Kafka replay after consumer restart
- Retry after ambiguous error (40003)
- Application logic error (true duplicate)

**Action:**
- For **idempotent operations**: Ignore and treat as success
- For **non-idempotent operations**: This indicates an application bug

**Implementation:**
```csharp
catch (PostgresException ex) when (ex.SqlState == "23505")
{
    // Our inserts use ON CONFLICT DO NOTHING, so this is rare
    // If it happens, data already exists - treat as success
    logger.LogDebug("Duplicate key ignored (23505)");
    return;
}
```

---

## Best Practices

### 1. Track Consecutive Failures

Prevent infinite retry loops:

```csharp
var consecutiveFailures = 0;
const int maxConsecutiveFailures = 5;

try
{
    await ProcessBatch(batch, connection);
    consecutiveFailures = 0; // Reset on success
}
catch (Exception ex)
{
    consecutiveFailures++;
    logger.LogError(ex, "Batch processing failed ({Failures}/{Max})",
        consecutiveFailures, maxConsecutiveFailures);
    
    if (consecutiveFailures >= maxConsecutiveFailures)
    {
        logger.LogError("Max consecutive failures exceeded, terminating");
        throw;
    }
    
    // Exponential backoff
    await Task.Delay(1000 * consecutiveFailures, cancellationToken);
}
```

### 2. Use Idempotency Keys

Make operations safely retryable:

```csharp
var idempotencyKey = $"{requestId}:{seqNum}:{actionStateLinkId}";

await cmd.ExecuteNonQueryAsync(@"
    INSERT INTO request_event_log (
        request_id, seq_num, action_state_link_id, status_id,
        event_ts, actor, metadata, idempotency_key
    )
    VALUES (@requestId, @seqNum, @actionStateLinkId, @statusId, @eventTs, @actor, @metadata, @idempotencyKey)
    ON CONFLICT (request_id, action_state_link_id, idempotency_key) DO NOTHING");
```

### 3. Exponential Backoff

Prevent thundering herd:

```csharp
var delayMs = (int)Math.Pow(2, retryAttempt) * 100;
// Attempt 1: 200ms
// Attempt 2: 400ms
// Attempt 3: 800ms
// Attempt 4: 1600ms
await Task.Delay(delayMs, cancellationToken);
```

### 4. Batch with Transactions

Process multiple events in a single transaction for efficiency:

```csharp
await using var transaction = await connection.BeginTransactionAsync();

foreach (var evt in batch)
{
    await ProcessEvent(evt, connection, transaction);
}

await transaction.CommitAsync(); // All or nothing
```

### 5. Manual Offset Store Pattern

Only store Kafka offsets after successful database commit:

```csharp
try
{
    await ProcessBatch(batch, connection);
    
    // Only store offsets after successful processing
    foreach (var evt in batch)
    {
        consumer.StoreOffset(new TopicPartitionOffset(topic, partition, evt.Offset + 1));
    }
}
catch (Exception)
{
    // Don't store offsets - will replay on restart
    throw;
}
```

---

## Error Handling Decision Tree

```
Exception Caught
    │
    ├─ 40001 (Serialization)?
    │   └─ YES → Retry entire transaction with exponential backoff
    │
    ├─ 40003 (Ambiguous)?
    │   └─ YES → Verify if committed, or treat as success if idempotent
    │
    ├─ 08xx/57xx (Connection)?
    │   └─ YES → Retry with new connection + backoff
    │
    ├─ 23505 (Unique violation)?
    │   └─ YES → Ignore if idempotent, log and investigate if not
    │
    └─ Other?
        └─ Log error, increment failure counter, terminate if max exceeded
```

---

## Testing Error Scenarios

### Simulate 40001 (Serialization)
```sql
-- Terminal 1
BEGIN;
UPDATE request_info SET description = 'test1' WHERE request_id = '...';
-- Don't commit yet

-- Terminal 2 (will get 40001)
UPDATE request_info SET description = 'test2' WHERE request_id = '...';
```

### Simulate 40003 (Ambiguous)
- Kill network connection during COMMIT
- Restart CockroachDB node during transaction

### Simulate 08006 (Connection Error)
```bash
# Restart PgBouncer
docker restart pgbouncer-us-east
```

---

## References

- [CockroachDB Transaction Retry Errors](https://www.cockroachlabs.com/docs/stable/transaction-retry-error-reference.html)
- [Npgsql Exception Handling](https://www.npgsql.org/doc/types/exceptions.html)
- [PostgreSQL Error Codes](https://www.postgresql.org/docs/current/errcodes-appendix.html)
- [CockroachDB JDBC Driver - Connection Errors](https://blog.cloudneutral.se/cockroachdb-jdbc-driver-part-ii-design-and-implementation-details#heading-connection-errors)
