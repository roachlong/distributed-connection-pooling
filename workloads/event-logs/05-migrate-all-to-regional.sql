-- Phase 3: Migrate All Remaining Tables to REGIONAL BY ROW
-- This script migrates request_info, request_event_log, request_status_head,
-- request_account_link, and trade_info to use REGIONAL BY ROW.
--
-- IMPORTANT: We explicitly set crdb_region during migration to co-locate
-- related data with account_info (which uses computed_region).

USE defaultdb;

-- Disable sql_safe_updates to allow in-place REGIONAL BY ROW conversion
SET sql_safe_updates = false;

-- =============================================================================
-- OVERVIEW
-- =============================================================================
-- Phase 3 completes the migration to multi-region abstractions by converting
-- all remaining transactional tables to REGIONAL BY ROW.
--
-- DATA CO-LOCATION STRATEGY:
-- - account_info uses REGIONAL BY ROW AS computed_region (deterministic)
-- - All related tables use REGIONAL BY ROW (default crdb_region)
-- - We override crdb_region during INSERT to match account's computed_region
-- - This ensures data locality regardless of gateway connection
--
-- For migration, we:
-- 1. Unlock schema (for changefeed-watched tables)
-- 2. ALTER TABLE SET LOCALITY REGIONAL BY ROW (adds implicit crdb_region column)
-- 3. UPDATE crdb_region to match parent table's region
-- 4. Lock schema (restore changefeed performance)
--
-- This approach:
-- - Keeps tables online during migration (no downtime)
-- - No data copy required (in-place conversion)
-- - Can be re-run to rebalance data if needed
--
-- APPLICATION CHANGES REQUIRED:
-- - When inserting request_info, set crdb_region to match account's computed_region
-- - When inserting request_event_log, inherit crdb_region from request_info
-- - When inserting trade_info, set crdb_region to match account's computed_region
-- - This ensures data locality despite gateway affinity
-- =============================================================================

-- =============================================================================
-- STEP 1: Migrate request_info to REGIONAL BY ROW
-- =============================================================================

-- Unlock schema
ALTER TABLE request_info SET (schema_locked = false);

-- Convert to REGIONAL BY ROW (adds implicit crdb_region column)
ALTER TABLE request_info SET LOCALITY REGIONAL BY ROW;

-- Set crdb_region to match account's computed_region
-- This co-locates requests with their primary account
UPDATE request_info ri
SET crdb_region = ai.computed_region
FROM account_info ai
WHERE ri.primary_account_number = ai.account_number;

-- Lock schema
ALTER TABLE request_info SET (schema_locked = true);

-- Verify row counts and distribution
SELECT 'request_info total' AS metric, COUNT(*)::STRING AS count FROM request_info
UNION ALL
SELECT 'request_info by region', crdb_region::STRING || ': ' || COUNT(*)::STRING
FROM request_info
GROUP BY crdb_region
ORDER BY metric;

-- =============================================================================
-- STEP 2: Migrate request_account_link to REGIONAL BY ROW
-- =============================================================================

-- Unlock schema
ALTER TABLE request_account_link SET (schema_locked = false);

-- Convert to REGIONAL BY ROW
ALTER TABLE request_account_link SET LOCALITY REGIONAL BY ROW;

-- Set crdb_region to match request's region
-- This co-locates account links with their request
UPDATE request_account_link ral
SET crdb_region = ri.crdb_region
FROM request_info ri
WHERE ral.request_id = ri.request_id;

-- Lock schema
ALTER TABLE request_account_link SET (schema_locked = true);

-- Verify row counts and distribution
SELECT 'request_account_link total' AS metric, COUNT(*)::STRING AS count FROM request_account_link
UNION ALL
SELECT 'request_account_link by region', crdb_region::STRING || ': ' || COUNT(*)::STRING
FROM request_account_link
GROUP BY crdb_region
ORDER BY metric;

-- =============================================================================
-- STEP 3: Migrate request_event_log to REGIONAL BY ROW
-- =============================================================================

-- Unlock schema
ALTER TABLE request_event_log SET (schema_locked = false);

-- Convert to REGIONAL BY ROW
ALTER TABLE request_event_log SET LOCALITY REGIONAL BY ROW;

-- Set crdb_region to match request's region
-- This co-locates event logs with their request
UPDATE request_event_log rel
SET crdb_region = ri.crdb_region
FROM request_info ri
WHERE rel.request_id = ri.request_id;

-- Lock schema
ALTER TABLE request_event_log SET (schema_locked = true);

-- Verify row counts and distribution
SELECT 'request_event_log total' AS metric, COUNT(*)::STRING AS count FROM request_event_log
UNION ALL
SELECT 'request_event_log by region', crdb_region::STRING || ': ' || COUNT(*)::STRING
FROM request_event_log
GROUP BY crdb_region
ORDER BY metric;

-- =============================================================================
-- STEP 4: Migrate request_status_head to REGIONAL BY ROW
-- =============================================================================

-- Unlock schema
ALTER TABLE request_status_head SET (schema_locked = false);

-- Convert to REGIONAL BY ROW
ALTER TABLE request_status_head SET LOCALITY REGIONAL BY ROW;

-- Set crdb_region to match request's region
-- This co-locates status head with their request
UPDATE request_status_head rsh
SET crdb_region = ri.crdb_region
FROM request_info ri
WHERE rsh.request_id = ri.request_id;

-- Lock schema
ALTER TABLE request_status_head SET (schema_locked = true);

-- Verify row counts and distribution
SELECT 'request_status_head total' AS metric, COUNT(*)::STRING AS count FROM request_status_head
UNION ALL
SELECT 'request_status_head by region', crdb_region::STRING || ': ' || COUNT(*)::STRING
FROM request_status_head
GROUP BY crdb_region
ORDER BY metric;

-- =============================================================================
-- STEP 5: Migrate trade_info to REGIONAL BY ROW
-- =============================================================================

-- Unlock schema
ALTER TABLE trade_info SET (schema_locked = false);

-- Convert to REGIONAL BY ROW
ALTER TABLE trade_info SET LOCALITY REGIONAL BY ROW;

-- Set crdb_region to match account's computed_region
-- This co-locates trades with their account
UPDATE trade_info ti
SET crdb_region = ai.computed_region
FROM account_info ai
WHERE ti.account_number = ai.account_number;

-- Lock schema
ALTER TABLE trade_info SET (schema_locked = true);

-- Verify row counts and distribution
SELECT 'trade_info total' AS metric, COUNT(*)::STRING AS count FROM trade_info
UNION ALL
SELECT 'trade_info by region', crdb_region::STRING || ': ' || COUNT(*)::STRING
FROM trade_info
GROUP BY crdb_region
ORDER BY metric;

-- Re-enable sql_safe_updates
SET sql_safe_updates = true;

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================

-- Check all table localities
SELECT
    schema_name,
    table_name,
    locality
FROM [SHOW TABLES]
WHERE schema_name = 'public'
ORDER BY table_name;

-- Verify regional distribution for each table
SELECT 'account_info' AS table_name, computed_region AS crdb_region, COUNT(*) AS row_count
FROM account_info
GROUP BY computed_region
UNION ALL
SELECT 'request_info', crdb_region, COUNT(*)
FROM request_info
GROUP BY crdb_region
UNION ALL
SELECT 'request_account_link', crdb_region, COUNT(*)
FROM request_account_link
GROUP BY crdb_region
UNION ALL
SELECT 'request_event_log', crdb_region, COUNT(*)
FROM request_event_log
GROUP BY crdb_region
UNION ALL
SELECT 'request_status_head', crdb_region, COUNT(*)
FROM request_status_head
GROUP BY crdb_region
UNION ALL
SELECT 'trade_info', crdb_region, COUNT(*)
FROM trade_info
GROUP BY crdb_region
ORDER BY table_name, crdb_region;

-- Verify data co-location: requests should be in same region as their account
-- This query checks if request_info.crdb_region matches account_info.computed_region
SELECT
    ai.computed_region AS account_region,
    ri.crdb_region AS request_region,
    COUNT(*) AS count,
    CASE
        WHEN ai.computed_region = ri.crdb_region THEN 'CO-LOCATED'
        ELSE 'MISMATCHED'
    END AS status
FROM request_info ri
JOIN account_info ai ON ri.primary_account_number = ai.account_number
GROUP BY ai.computed_region, ri.crdb_region
ORDER BY status DESC, account_region;

-- Verify data co-location: trades should be in same region as their account
SELECT
    ai.computed_region AS account_region,
    ti.crdb_region AS trade_region,
    COUNT(*) AS count,
    CASE
        WHEN ai.computed_region = ti.crdb_region THEN 'CO-LOCATED'
        ELSE 'MISMATCHED'
    END AS status
FROM trade_info ti
JOIN account_info ai ON ti.account_number = ai.account_number
GROUP BY ai.computed_region, ti.crdb_region
ORDER BY status DESC, account_region;

-- =============================================================================
-- NOTES
-- =============================================================================
--
-- 1. Application Changes REQUIRED:
--    - When inserting request_info, lookup account's region and set crdb_region
--    - When inserting request_event_log, inherit crdb_region from request_info
--    - When inserting trade_info, lookup account's region and set crdb_region
--    - Example pattern:
--      ```sql
--      INSERT INTO request_info (request_id, primary_account_number, ..., crdb_region)
--      SELECT gen_random_uuid(), @account_number, ..., computed_region
--      FROM account_info
--      WHERE account_number = @account_number;
--      ```
--
-- 2. Data Co-Location Benefits:
--    - All data for an account lives in the same region
--    - Local reads/writes are fast (no cross-region latency)
--    - Transactions involving related data are local (no distributed commits)
--    - Better performance for account-centric queries
--
-- 3. Gateway Affinity Override:
--    - By default, REGIONAL BY ROW uses gateway_region()
--    - We override this by explicitly setting crdb_region in INSERT
--    - This gives us deterministic placement based on business logic
--    - Application controls placement, not connection gateway
--
-- 4. Foreign Keys:
--    - Cross-region foreign keys work fine
--    - Example: request in us-east can reference global config tables
--    - CockroachDB handles cross-region lookups automatically
--    - But we minimize cross-region access by co-locating related data
--
-- 5. Performance Impact:
--    - Writes to correct region (matched to account) regardless of gateway
--    - Local reads are fast (read from local leaseholder)
--    - Cross-region reads only for global config tables (cached locally)
--    - Follower reads can further reduce latency for stale-OK queries
--
-- 6. CDC Configuration:
--    - After this migration, create regional changefeeds
--    - See 06-create-regional-changefeeds.sql for CDC setup
--    - Regional changefeeds filter by crdb_region for regional Kafka topics
--
-- 7. Hybrid Strategy Summary:
--    - account_info: REGIONAL BY ROW AS computed_region (from locality hash)
--    - request_info, events, trades: REGIONAL BY ROW (explicit crdb_region override)
--    - Configuration tables: GLOBAL (cached in all regions)
--    - Result: Data co-location with deterministic placement
--
-- 8. Migration Data Flow:
--    - account_info.computed_region is the source of truth for region assignment
--    - request_info.crdb_region copies from account_info.computed_region
--    - request_event_log.crdb_region copies from request_info.crdb_region
--    - trade_info.crdb_region copies from account_info.computed_region
--    - This ensures entire entity graph is co-located in the same region
--
-- 9. Rebalancing Data:
--    - This script can be re-run to rebalance data if account locality changes
--    - Just re-run the UPDATE statements for any table that needs rebalancing
--    - Tables stay online during rebalancing (no downtime)
--    - Example: If account localities are recalculated, update request_info:
--      UPDATE request_info ri SET crdb_region = ai.computed_region
--      FROM account_info ai WHERE ri.primary_account_number = ai.account_number;
--
-- 10. Migration Approach:
--     - In-place conversion (no table copy/rename)
--     - Tables stay online during migration (zero downtime)
--     - Much faster than copy/rename approach
--     - Only account_info required copy/rename (primary key structure change)
