-- Validation Queries for Multi-Region Data Locality
-- Run these after the workload has generated data to verify locality alignment

USE defaultdb;

-- =============================================================================
-- 1. Account Distribution Across Localities and Regions
-- =============================================================================
-- Shows how accounts are distributed across localities and computed regions
-- Should see roughly even distribution (30 buckets across 3 regions)

SELECT
  locality,
  computed_region::TEXT AS region,
  COUNT(*) AS account_count
FROM account_info
GROUP BY locality, computed_region
ORDER BY locality;

-- Summary by region
SELECT
  computed_region::TEXT AS region,
  COUNT(*) AS total_accounts
FROM account_info
GROUP BY computed_region
ORDER BY computed_region;

-- =============================================================================
-- 2. Request Locality Alignment (CRITICAL CHECK WITH SCORE)
-- =============================================================================
-- Verifies that requests landed in the same region as their primary account
-- *** Target: 100% correct alignment ***

WITH alignment_check AS (
  SELECT
    ai.locality,
    ai.computed_region::TEXT AS expected_region,
    ri.crdb_region::TEXT AS actual_region,
    CASE
      WHEN ai.computed_region::TEXT = ri.crdb_region::TEXT THEN 1
      ELSE 0
    END AS is_correct
  FROM account_info ai
  JOIN request_info ri ON ai.account_id = ri.primary_account_id
)
SELECT
  'Request-Account Alignment' AS check_name,
  COUNT(*) AS total_records,
  SUM(is_correct) AS correct_count,
  COUNT(*) - SUM(is_correct) AS mismatch_count,
  ROUND((SUM(is_correct)::DECIMAL / COUNT(*)) * 100, 2) AS success_percentage
FROM alignment_check;

-- Detailed breakdown if mismatches exist
SELECT
  expected_region,
  actual_region,
  COUNT(*) AS mismatch_count
FROM (
  SELECT
    ai.computed_region::TEXT AS expected_region,
    ri.crdb_region::TEXT AS actual_region
  FROM account_info ai
  JOIN request_info ri ON ai.account_id = ri.primary_account_id
  WHERE ai.computed_region::TEXT != ri.crdb_region::TEXT
)
GROUP BY expected_region, actual_region
ORDER BY mismatch_count DESC;

-- =============================================================================
-- 3. Event Log Locality Alignment (CRITICAL CHECK WITH SCORE)
-- =============================================================================
-- Verifies that request events landed in the same region as their request
-- *** Target: 100% correct alignment ***

WITH event_alignment AS (
  SELECT
    ri.crdb_region::TEXT AS request_region,
    rel.crdb_region::TEXT AS event_region,
    CASE
      WHEN ri.crdb_region = rel.crdb_region THEN 1
      ELSE 0
    END AS is_correct
  FROM request_info ri
  JOIN request_event_log rel ON ri.request_id = rel.request_id
)
SELECT
  'Event-Request Alignment' AS check_name,
  COUNT(*) AS total_records,
  SUM(is_correct) AS correct_count,
  COUNT(*) - SUM(is_correct) AS mismatch_count,
  ROUND((SUM(is_correct)::DECIMAL / COUNT(*)) * 100, 2) AS success_percentage
FROM event_alignment;

-- Detailed breakdown if mismatches exist
SELECT
  ri.crdb_region AS request_region,
  rel.crdb_region AS event_region,
  COUNT(*) AS mismatch_count
FROM request_info ri
JOIN request_event_log rel ON ri.request_id = rel.request_id
WHERE ri.crdb_region != rel.crdb_region
GROUP BY request_region, event_region
ORDER BY mismatch_count DESC;

-- =============================================================================
-- 4. Trade Locality Alignment (CRITICAL CHECK WITH SCORE)
-- =============================================================================
-- Verifies that trades landed in the same region as their account
-- *** Target: 100% correct alignment ***

WITH trade_alignment AS (
  SELECT
    ai.computed_region::TEXT AS expected_region,
    ti.crdb_region::TEXT AS actual_region,
    CASE
      WHEN ai.computed_region::TEXT = ti.crdb_region::TEXT THEN 1
      ELSE 0
    END AS is_correct
  FROM account_info ai
  JOIN trade_info ti ON ai.account_id = ti.account_id
)
SELECT
  'Trade-Account Alignment' AS check_name,
  COUNT(*) AS total_records,
  SUM(is_correct) AS correct_count,
  COUNT(*) - SUM(is_correct) AS mismatch_count,
  ROUND((SUM(is_correct)::DECIMAL / COUNT(*)) * 100, 2) AS success_percentage
FROM trade_alignment;

-- Detailed breakdown if mismatches exist
SELECT
  expected_region,
  actual_region,
  COUNT(*) AS mismatch_count
FROM (
  SELECT
    ai.computed_region::TEXT AS expected_region,
    ti.crdb_region::TEXT AS actual_region
  FROM account_info ai
  JOIN trade_info ti ON ai.account_id = ti.account_id
  WHERE ai.computed_region::TEXT != ti.crdb_region::TEXT
)
GROUP BY expected_region, actual_region
ORDER BY mismatch_count DESC;

-- =============================================================================
-- 5. Request Status Head Alignment (CRITICAL CHECK WITH SCORE)
-- =============================================================================
-- Verifies status head is co-located with request

WITH status_head_alignment AS (
  SELECT
    ri.crdb_region::TEXT AS request_region,
    rsh.crdb_region::TEXT AS status_head_region,
    CASE
      WHEN ri.crdb_region = rsh.crdb_region THEN 1
      ELSE 0
    END AS is_correct
  FROM request_info ri
  JOIN request_status_head rsh ON ri.request_id = rsh.request_id
)
SELECT
  'StatusHead-Request Alignment' AS check_name,
  COUNT(*) AS total_records,
  SUM(is_correct) AS correct_count,
  COUNT(*) - SUM(is_correct) AS mismatch_count,
  ROUND((SUM(is_correct)::DECIMAL / COUNT(*)) * 100, 2) AS success_percentage
FROM status_head_alignment;

-- =============================================================================
-- 6. Leaseholder Distribution by Table
-- =============================================================================
-- Uses SHOW RANGES to verify leaseholders align with crdb_region
-- This proves data physically resides in the correct region

-- Account Info (should align with computed_region from locality buckets)
SELECT
  'account_info' AS table_name,
  lease_holder_locality,
  COUNT(*) AS range_count
FROM [SHOW RANGES FROM TABLE account_info WITH DETAILS]
GROUP BY lease_holder_locality
ORDER BY lease_holder_locality;

-- Request Info (should align with crdb_region for REGIONAL BY ROW)
SELECT
  'request_info' AS table_name,
  lease_holder_locality,
  COUNT(*) AS range_count
FROM [SHOW RANGES FROM TABLE request_info WITH DETAILS]
GROUP BY lease_holder_locality
ORDER BY lease_holder_locality;

-- Request Event Log
SELECT
  'request_event_log' AS table_name,
  lease_holder_locality,
  COUNT(*) AS range_count
FROM [SHOW RANGES FROM TABLE request_event_log WITH DETAILS]
GROUP BY lease_holder_locality
ORDER BY lease_holder_locality;

-- Trade Info
SELECT
  'trade_info' AS table_name,
  lease_holder_locality,
  COUNT(*) AS range_count
FROM [SHOW RANGES FROM TABLE trade_info WITH DETAILS]
GROUP BY lease_holder_locality
ORDER BY lease_holder_locality;

-- Request Status Head
SELECT
  'request_status_head' AS table_name,
  lease_holder_locality,
  COUNT(*) AS range_count
FROM [SHOW RANGES FROM TABLE request_status_head WITH DETAILS]
GROUP BY lease_holder_locality
ORDER BY lease_holder_locality;

-- =============================================================================
-- 7. Replica Locality Distribution (Sample)
-- =============================================================================
-- Shows all replica localities for each table
-- For SURVIVE REGION FAILURE, should see 3+ replicas per range spread across regions

SELECT
  'account_info' AS table_name,
  start_key,
  end_key,
  array_length(replicas, 1) AS replica_count,
  replica_localities,
  lease_holder_locality
FROM [SHOW RANGES FROM TABLE account_info WITH DETAILS]
ORDER BY start_key
LIMIT 10;

SELECT
  'request_info' AS table_name,
  start_key,
  end_key,
  array_length(replicas, 1) AS replica_count,
  replica_localities,
  lease_holder_locality
FROM [SHOW RANGES FROM TABLE request_info WITH DETAILS]
ORDER BY start_key
LIMIT 10;

-- =============================================================================
-- 8. Row Count by Region (from crdb_region)
-- =============================================================================
-- Shows data distribution for REGIONAL BY ROW tables

SELECT
  'request_info' AS table_name,
  crdb_region,
  COUNT(*) AS row_count
FROM request_info
GROUP BY crdb_region
ORDER BY crdb_region;

SELECT
  'request_event_log' AS table_name,
  crdb_region,
  COUNT(*) AS row_count
FROM request_event_log
GROUP BY crdb_region
ORDER BY crdb_region;

SELECT
  'trade_info' AS table_name,
  crdb_region,
  COUNT(*) AS row_count
FROM trade_info
GROUP BY crdb_region
ORDER BY crdb_region;

SELECT
  'request_status_head' AS table_name,
  crdb_region,
  COUNT(*) AS row_count
FROM request_status_head
GROUP BY crdb_region
ORDER BY crdb_region;

-- =============================================================================
-- 9. Cross-Region Request Detection
-- =============================================================================
-- Detects requests that involve accounts from multiple regions
-- (via request_account_link)
-- These are expected but show complexity

WITH regional_accounts AS (
  SELECT
    ri.request_id,
    ri.crdb_region AS request_region,
    ai.computed_region::STRING AS account_region
  FROM request_info ri
  JOIN request_account_link ral ON ri.request_id = ral.request_id
  JOIN account_info ai ON ral.account_id = ai.account_id
)
SELECT
  request_id,
  request_region,
  STRING_AGG(DISTINCT account_region, ', ') AS linked_account_regions,
  COUNT(DISTINCT account_region) AS unique_regions,
  COUNT(*) AS total_linked_accounts
FROM regional_accounts
GROUP BY request_id, request_region
HAVING COUNT(DISTINCT account_region) > 1
ORDER BY unique_regions DESC, total_linked_accounts DESC
LIMIT 20;

-- =============================================================================
-- 10. Workflow Progression Summary by Region
-- =============================================================================

SELECT
  ri.crdb_region,
  rs.status_code,
  COUNT(*) AS request_count
FROM request_info ri
JOIN request_status rs ON ri.request_status_id = rs.status_id
GROUP BY ri.crdb_region, rs.status_code
ORDER BY ri.crdb_region, rs.status_code;

-- =============================================================================
-- 11. Event Activity by Region and Action
-- =============================================================================

SELECT
  rel.crdb_region,
  rat.action_code,
  COUNT(*) AS event_count
FROM request_event_log rel
JOIN request_action_state_link rasl ON rel.action_state_link_id = rasl.action_state_link_id
JOIN request_action_type rat ON rasl.action_type_id = rat.action_type_id
GROUP BY rel.crdb_region, rat.action_code
ORDER BY rel.crdb_region, event_count DESC;

-- =============================================================================
-- 12. Trade Volume by Account Home Region
-- =============================================================================

SELECT
  ai.computed_region::TEXT AS account_region,
  ti.side,
  COUNT(*) AS trade_count,
  SUM(ti.quantity) AS total_quantity
FROM account_info ai
JOIN trade_info ti ON ai.account_id = ti.account_id
GROUP BY ai.computed_region, ti.side
ORDER BY ai.computed_region, ti.side;

-- =============================================================================
-- 13. CONSOLIDATED VALIDATION SCORECARD
-- =============================================================================
-- Shows all critical checks with success scores
-- *** Target: 100% for all checks ***

WITH request_alignment AS (
  SELECT
    CASE WHEN ai.computed_region = ri.crdb_region THEN 1 ELSE 0 END AS is_correct
  FROM account_info ai
  JOIN request_info ri ON ai.account_id = ri.primary_account_id
),
event_alignment AS (
  SELECT
    CASE WHEN ri.crdb_region = rel.crdb_region THEN 1 ELSE 0 END AS is_correct
  FROM request_info ri
  JOIN request_event_log rel ON ri.request_id = rel.request_id
),
trade_alignment AS (
  SELECT
    CASE WHEN ai.computed_region = ti.crdb_region THEN 1 ELSE 0 END AS is_correct
  FROM account_info ai
  JOIN trade_info ti ON ai.account_id = ti.account_id
),
status_head_alignment AS (
  SELECT
    CASE WHEN ri.crdb_region = rsh.crdb_region THEN 1 ELSE 0 END AS is_correct
  FROM request_info ri
  JOIN request_status_head rsh ON ri.request_id = rsh.request_id
)
SELECT 'Request-Account Alignment' AS check_name,
       COUNT(*) AS total,
       SUM(is_correct) AS correct,
       COUNT(*) - SUM(is_correct) AS mismatches,
       ROUND((SUM(is_correct)::DECIMAL / COUNT(*)) * 100, 2) AS score_pct
FROM request_alignment
UNION ALL
SELECT 'Event-Request Alignment',
       COUNT(*),
       SUM(is_correct),
       COUNT(*) - SUM(is_correct),
       ROUND((SUM(is_correct)::DECIMAL / COUNT(*)) * 100, 2)
FROM event_alignment
UNION ALL
SELECT 'Trade-Account Alignment',
       COUNT(*),
       SUM(is_correct),
       COUNT(*) - SUM(is_correct),
       ROUND((SUM(is_correct)::DECIMAL / COUNT(*)) * 100, 2)
FROM trade_alignment
UNION ALL
SELECT 'StatusHead-Request Alignment',
       COUNT(*),
       SUM(is_correct),
       COUNT(*) - SUM(is_correct),
       ROUND((SUM(is_correct)::DECIMAL / COUNT(*)) * 100, 2)
FROM status_head_alignment;
