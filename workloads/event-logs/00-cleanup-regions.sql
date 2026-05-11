-- =============================================================================
-- CLEANUP: Remove multi-region abstractions from defaultdb
-- =============================================================================
-- Run this script ONLY if you have multi-region configured and want to remove it.
-- Check first with: SHOW REGIONS FROM DATABASE defaultdb;
--
-- If you see "0 rows", you don't need to run this script.
-- If you see regions listed, run this script to clean them up.
-- =============================================================================

USE defaultdb;

-- Step 1: Downgrade survival goal (required before dropping regions)
ALTER DATABASE defaultdb SURVIVE ZONE FAILURE;

-- Step 2: Drop non-primary regions
ALTER DATABASE defaultdb DROP REGION "us-central";
ALTER DATABASE defaultdb DROP REGION "us-west";

-- Step 3: Drop the primary region (returns database to non-multi-region state)
ALTER DATABASE defaultdb DROP REGION "us-east";

-- Verify cleanup
SHOW REGIONS FROM DATABASE defaultdb;
-- Should show "0 rows" after successful cleanup
