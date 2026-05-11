-- Rebalance Regional Data
-- This script reassigns crdb_region values to match the account's home region
--
-- Use cases:
-- 1. After a region failure/recovery (data may have been written to wrong region)
-- 2. After changing account localities (propagate region changes to child tables)
-- 3. Manual rebalancing to optimize data placement
--
-- This is safe to run repeatedly - it's idempotent

USE defaultdb;

SET sql_safe_updates = false;

-- =============================================================================
-- STEP 1: Rebalance request_info
-- =============================================================================
-- Ensure requests are co-located with their primary account

-- Unlock schema
ALTER TABLE request_info SET (schema_locked = false);

-- Update crdb_region to match account's computed_region
UPDATE request_info ri
SET crdb_region = ai.computed_region
FROM account_info ai
WHERE ri.primary_account_number = ai.account_number
  AND ri.crdb_region != ai.computed_region;  -- Only update mismatched rows

-- Lock schema
ALTER TABLE request_info SET (schema_locked = true);

-- Report changes
SELECT 'request_info rebalanced' AS status, COUNT(*) AS rows_updated
FROM request_info ri
JOIN account_info ai ON ri.primary_account_number = ai.account_number
WHERE ri.crdb_region = ai.computed_region;

-- =============================================================================
-- STEP 2: Rebalance request_account_link
-- =============================================================================
-- Ensure account links are co-located with their request

-- Unlock schema
ALTER TABLE request_account_link SET (schema_locked = false);

-- Update crdb_region to match request's region
UPDATE request_account_link ral
SET crdb_region = ri.crdb_region
FROM request_info ri
WHERE ral.request_id = ri.request_id
  AND ral.crdb_region != ri.crdb_region;  -- Only update mismatched rows

-- Lock schema
ALTER TABLE request_account_link SET (schema_locked = true);

-- Report changes
SELECT 'request_account_link rebalanced' AS status, COUNT(*) AS rows_updated
FROM request_account_link ral
JOIN request_info ri ON ral.request_id = ri.request_id
WHERE ral.crdb_region = ri.crdb_region;

-- =============================================================================
-- STEP 3: Rebalance request_event_log
-- =============================================================================
-- Ensure event logs are co-located with their request

-- Unlock schema
ALTER TABLE request_event_log SET (schema_locked = false);

-- Update crdb_region to match request's region
UPDATE request_event_log rel
SET crdb_region = ri.crdb_region
FROM request_info ri
WHERE rel.request_id = ri.request_id
  AND rel.crdb_region != ri.crdb_region;  -- Only update mismatched rows

-- Lock schema
ALTER TABLE request_event_log SET (schema_locked = true);

-- Report changes
SELECT 'request_event_log rebalanced' AS status, COUNT(*) AS rows_updated
FROM request_event_log rel
JOIN request_info ri ON rel.request_id = ri.request_id
WHERE rel.crdb_region = ri.crdb_region;

-- =============================================================================
-- STEP 4: Rebalance request_status_head
-- =============================================================================
-- Ensure status head is co-located with their request

-- Unlock schema
ALTER TABLE request_status_head SET (schema_locked = false);

-- Update crdb_region to match request's region
UPDATE request_status_head rsh
SET crdb_region = ri.crdb_region
FROM request_info ri
WHERE rsh.request_id = ri.request_id
  AND rsh.crdb_region != ri.crdb_region;  -- Only update mismatched rows

-- Lock schema
ALTER TABLE request_status_head SET (schema_locked = true);

-- Report changes
SELECT 'request_status_head rebalanced' AS status, COUNT(*) AS rows_updated
FROM request_status_head rsh
JOIN request_info ri ON rsh.request_id = ri.request_id
WHERE rsh.crdb_region = ri.crdb_region;

-- =============================================================================
-- STEP 5: Rebalance trade_info
-- =============================================================================
-- Ensure trades are co-located with their account

-- Unlock schema
ALTER TABLE trade_info SET (schema_locked = false);

-- Update crdb_region to match account's computed_region
UPDATE trade_info ti
SET crdb_region = ai.computed_region
FROM account_info ai
WHERE ti.account_number = ai.account_number
  AND ti.crdb_region != ai.computed_region;  -- Only update mismatched rows

-- Lock schema
ALTER TABLE trade_info SET (schema_locked = true);

-- Report changes
SELECT 'trade_info rebalanced' AS status, COUNT(*) AS rows_updated
FROM trade_info ti
JOIN account_info ai ON ti.account_number = ai.account_number
WHERE ti.crdb_region = ai.computed_region;

-- Re-enable sql_safe_updates
SET sql_safe_updates = true;

-- =============================================================================
-- VERIFICATION: Check for any remaining mismatches
-- =============================================================================

-- Check request_info mismatches
SELECT 'request_info mismatches' AS check_name, COUNT(*) AS mismatch_count
FROM request_info ri
JOIN account_info ai ON ri.primary_account_number = ai.account_number
WHERE ri.crdb_region != ai.computed_region
UNION ALL
-- Check trade_info mismatches
SELECT 'trade_info mismatches', COUNT(*)
FROM trade_info ti
JOIN account_info ai ON ti.account_number = ai.account_number
WHERE ti.crdb_region != ai.computed_region
UNION ALL
-- Check request_event_log mismatches
SELECT 'request_event_log mismatches', COUNT(*)
FROM request_event_log rel
JOIN request_info ri ON rel.request_id = ri.request_id
WHERE rel.crdb_region != ri.crdb_region
UNION ALL
-- Check request_status_head mismatches
SELECT 'request_status_head mismatches', COUNT(*)
FROM request_status_head rsh
JOIN request_info ri ON rsh.request_id = ri.request_id
WHERE rsh.crdb_region != ri.crdb_region
UNION ALL
-- Check request_account_link mismatches
SELECT 'request_account_link mismatches', COUNT(*)
FROM request_account_link ral
JOIN request_info ri ON ral.request_id = ri.request_id
WHERE ral.crdb_region != ri.crdb_region;

-- =============================================================================
-- NOTES
-- =============================================================================
--
-- 1. When to run this script:
--    - After a region failure/recovery if data was written during the outage
--    - After bulk changes to account_info.locality values
--    - As a periodic maintenance task to ensure optimal data placement
--    - Before performance testing to ensure clean baseline
--
-- 2. Performance impact:
--    - Updates only mismatched rows (uses WHERE clause filter)
--    - Can run on live system (tables stay online)
--    - Schema locks briefly released/reacquired for each table
--    - CockroachDB will gradually move data to correct regions in background
--
-- 3. Safety:
--    - Idempotent - safe to run multiple times
--    - Only updates rows where crdb_region doesn't match parent
--    - Does NOT change account_info.computed_region (that's the source of truth)
--
-- 4. What happens after running:
--    - crdb_region values updated immediately
--    - CockroachDB asynchronously moves data to match new crdb_region
--    - Leaseholders migrate to home regions
--    - No application downtime required
--
-- 5. Monitoring rebalancing progress:
--    - Check CockroachDB admin UI for replica movement
--    - Watch range rebalancing metrics
--    - Query crdb_internal.ranges to see replica distribution
