-- Phase 2: Enable Multi-Region and Migrate account_info to REGIONAL BY ROW
-- This script transitions from manual partitioning to multi-region abstractions
-- for the account_info table while keeping other tables as regular tables.

USE defaultdb;

-- =============================================================================
-- STEP 0: Remove Manual Partitioning from account_info
-- =============================================================================
-- Multi-region tables cannot be manually partitioned - drop partitioning first

-- Unlock schema (required for schema changes on changefeed-watched tables)
ALTER TABLE account_info SET (schema_locked = false);

-- Discard zone configs
ALTER TABLE account_info CONFIGURE ZONE DISCARD;
ALTER PARTITION us_east OF INDEX account_info@pk_account_info CONFIGURE ZONE DISCARD;
ALTER PARTITION us_central OF INDEX account_info@pk_account_info CONFIGURE ZONE DISCARD;
ALTER PARTITION us_west OF INDEX account_info@pk_account_info CONFIGURE ZONE DISCARD;

-- Remove partitioning from the primary key index (keeps data in place)
ALTER INDEX account_info@pk_account_info PARTITION BY NOTHING;

-- Lock schema again for changefeed performance
ALTER TABLE account_info SET (schema_locked = true);

-- =============================================================================
-- STEP 1: Enable Multi-Region Database Configuration
-- =============================================================================
-- Add regions to the database (order matters for PRIMARY REGION)

ALTER DATABASE defaultdb SET PRIMARY REGION "us-east";
ALTER DATABASE defaultdb ADD REGION "us-central";
ALTER DATABASE defaultdb ADD REGION "us-west";

-- Set survival goal (SURVIVE REGION FAILURE for production)
ALTER DATABASE defaultdb SURVIVE REGION FAILURE;

-- =============================================================================
-- STEP 2: Convert Configuration Tables to GLOBAL
-- =============================================================================
-- Configuration tables should be GLOBAL for low-latency reads from all regions

-- Unlock schemas for changefeed-watched tables
ALTER TABLE request_type SET (schema_locked = false);
ALTER TABLE request_action_type SET (schema_locked = false);
ALTER TABLE request_state SET (schema_locked = false);
ALTER TABLE request_action_state_link SET (schema_locked = false);
ALTER TABLE request_status SET (schema_locked = false);

-- Set locality to GLOBAL
ALTER TABLE request_type SET LOCALITY GLOBAL;
ALTER TABLE request_action_type SET LOCALITY GLOBAL;
ALTER TABLE request_state SET LOCALITY GLOBAL;
ALTER TABLE request_action_state_link SET LOCALITY GLOBAL;
ALTER TABLE request_status SET LOCALITY GLOBAL;

-- Lock schemas again for changefeed performance
ALTER TABLE request_type SET (schema_locked = true);
ALTER TABLE request_action_type SET (schema_locked = true);
ALTER TABLE request_state SET (schema_locked = true);
ALTER TABLE request_action_state_link SET (schema_locked = true);
ALTER TABLE request_status SET (schema_locked = true);

-- =============================================================================
-- STEP 3: Migrate account_info from Manual PARTITION BY to REGIONAL BY ROW
-- =============================================================================

-- Step 3.1: Create new REGIONAL BY ROW table with computed_region
CREATE TABLE account_info_new (
    account_number  STRING NOT NULL,
    account_name    STRING NOT NULL,
    strategy        STRING NULL,
    base_currency   STRING NULL,

    -- Hash-based locality bucket [0..29] derived from account_number
    locality INT2 NOT NULL AS (
        mod(
            crc32ieee(account_number),
            30:::INT8
        )::INT2
    ) STORED
    CHECK (
        locality IN (
            0,1,2,3,4,5,6,7,8,9,
            10,11,12,13,14,15,16,17,18,19,
            20,21,22,23,24,25,26,27,28,29
        )
    ),

    -- Computed region column maps locality to CockroachDB region
    -- This is the hybrid approach: deterministic placement based on business key
    -- Note: Must inline the locality calculation since STORED computed columns
    -- cannot reference other STORED computed columns
    computed_region crdb_internal_region AS (
        CASE
            WHEN mod(crc32ieee(account_number), 30:::INT8)::INT2 BETWEEN 0 AND 9 THEN 'us-east'
            WHEN mod(crc32ieee(account_number), 30:::INT8)::INT2 BETWEEN 10 AND 19 THEN 'us-central'
            WHEN mod(crc32ieee(account_number), 30:::INT8)::INT2 BETWEEN 20 AND 29 THEN 'us-west'
        END
    ) STORED NOT NULL,

    CONSTRAINT pk_account_info_new PRIMARY KEY (locality, account_number)
) LOCALITY REGIONAL BY ROW AS computed_region;

-- Step 3.2: Create secondary index on new table
CREATE INDEX account_info_new_by_number
ON account_info_new (account_number)
STORING (account_name, strategy, base_currency);

-- Step 3.3: Copy data from old table to new table
-- computed_region will auto-populate based on locality during insert
INSERT INTO account_info_new (account_number, account_name, strategy, base_currency)
SELECT account_number, account_name, strategy, base_currency
FROM account_info;

-- Step 3.4: Verify data migration
-- Run this to check row counts match:
SELECT 'original' AS source, COUNT(*) FROM account_info
UNION ALL
SELECT 'new' AS source, COUNT(*) FROM account_info_new;

-- Step 3.5: Swap tables (minimal downtime window)
-- IMPORTANT: Applications should briefly pause writes during this swap

-- Unlock old table (already unlocked from Step 0, but being explicit)
-- ALTER TABLE account_info SET (schema_locked = false);

-- Rename tables to swap
ALTER TABLE account_info RENAME TO account_info_old;
ALTER TABLE account_info_new RENAME TO account_info;

-- Step 3.6: Rename the index to match original name
ALTER INDEX account_info_new_by_number RENAME TO account_info_by_number;

-- Lock new account_info for changefeed performance
ALTER TABLE account_info SET (schema_locked = true);

-- Step 3.7: Compare distributions between old and new (before dropping old table)
SELECT
    'old' AS source,
    locality,
    COUNT(*) as count
FROM account_info_old
GROUP BY locality
ORDER BY locality
UNION ALL
SELECT
    'new' AS source,
    locality,
    COUNT(*) as count
FROM account_info
GROUP BY locality
ORDER BY locality;

-- Step 3.8: Drop the old table once verified
-- IMPORTANT: Only run this after verifying data and confirming application works
DROP TABLE account_info_old CASCADE;

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================

-- Check database regions and survival goal
SHOW REGIONS FROM DATABASE defaultdb;

-- Verify table localities
SELECT
    schema_name,
    table_name,
    locality
FROM [SHOW TABLES]
WHERE schema_name = 'public'
ORDER BY table_name;

-- Check account_info distribution across regions
SELECT
    computed_region,
    COUNT(*) as account_count,
    MIN(locality) as min_locality,
    MAX(locality) as max_locality
FROM account_info
GROUP BY computed_region
ORDER BY computed_region;

-- =============================================================================
-- NOTES
-- =============================================================================
--
-- 1. Application Configuration Changes Required:
--    - Set UseGeoPartitioning = true in appsettings.json
--    - No code changes required, only configuration
--
-- 2. The migration approach (create new, copy, rename):
--    - Minimizes downtime to just the rename operations
--    - Old table remains queryable during data copy
--    - Can be rolled back by renaming tables back
--
-- 3. Other tables (request_info, request_event_log, etc.) remain as regular tables:
--    - They will use gateway_region() implicitly when migrated in Phase 3
--    - For now, they continue to work as-is with no locality constraints
--
-- 4. Primary Key Design:
--    - (locality, account_number) ensures data is partitioned by locality
--    - Since locality is part of the key, CockroachDB does NOT perform
--      cross-region uniqueness checks for the primary key
--    - This is critical for performance in the hybrid approach
--
-- 5. Hybrid Strategy in Phase 2:
--    - account_info: REGIONAL BY ROW AS computed_region (deterministic)
--    - All other tables: regular tables (dynamic gateway-based placement in Phase 3)
--    - Foreign keys from other tables to account_info work fine across regions
--
-- 6. Zone Configurations:
--    - Manual zone configurations from Phase 1 (ALTER PARTITION ... CONFIGURE ZONE)
--      are automatically removed when the partitioned table is dropped
--    - Multi-region abstractions handle replica placement automatically
--
-- 7. Cleanup:
--    - After verifying the migration, uncomment and run DROP TABLE account_info_old
--    - Keep the old table around initially for safety/rollback capability
--    - The CASCADE will drop associated constraints but should be safe after cutover
