-- Phase 3: Create Regional Changefeeds for Event Streaming
-- This script creates regional changefeeds for request_event_log table that
-- filter by crdb_region to send data to region-specific Kafka topics.

-- =============================================================================
-- OVERVIEW
-- =============================================================================
-- After migrating request_event_log to REGIONAL BY ROW, we can create regional
-- changefeeds that filter by crdb_region. This allows:
-- - Each region's events to flow to a regional Kafka topic
-- - Regional consumers to process only their region's events
-- - Better throughput and lower latency than global changefeeds
-- - Parallel processing of regional event streams
--
-- ARCHITECTURE:
-- - 3 changefeeds for request_event_log (one per region)
-- - Each changefeed filters WHERE crdb_region = '<region>'
-- - Data flows to regional Kafka topics: event-logs-us-<region>
-- - Regional consumers subscribe to their region's topic only
--
-- MIGRATION FROM PHASE 1-2:
-- - Phase 1-2: Single global changefeed → global topic → consumer group
-- - Phase 3: Regional changefeeds → regional topics → regional consumers
-- =============================================================================

-- =============================================================================
-- KAFKA CONFIGURATION
-- =============================================================================
-- This script uses localhost:9093 (single Kafka cluster) for simplicity.
--
-- For production multi-region Kafka:
-- - Option 1: Regional Kafka clusters (best performance)
--   Update kafka:// URLs to regional endpoints (kafka-us-east, kafka-us-central, etc.)
--   Each changefeed connects to its regional Kafka cluster
-- - Option 2: Single global Kafka cluster (simpler, used here)
--   All changefeeds connect to same endpoint (localhost:9093)
--   Topics are logically partitioned by region suffix
-- =============================================================================

-- =============================================================================
-- US-EAST REGIONAL CHANGEFEED
-- =============================================================================

CREATE CHANGEFEED
INTO 'kafka://kafka:9093?topic_name=request-events.us-east'
WITH
    initial_scan = 'no',
    key_column = 'request_id',
    unordered,
    kafka_sink_config = '{"RequiredAcks": "ONE"}',
    cursor = 'now()'
AS SELECT request_id, seq_num, action_state_link_id, status_id, 
          event_ts, actor, metadata, idempotency_key, crdb_region
FROM request_event_log
WHERE crdb_region = 'us-east';

-- =============================================================================
-- US-CENTRAL REGIONAL CHANGEFEED
-- =============================================================================

CREATE CHANGEFEED
INTO 'kafka://kafka:9093?topic_name=request-events.us-central'
WITH
    initial_scan = 'no',
    key_column = 'request_id',
    unordered,
    kafka_sink_config = '{"RequiredAcks": "ONE"}',
    cursor = 'now()'
AS SELECT request_id, seq_num, action_state_link_id, status_id, 
          event_ts, actor, metadata, idempotency_key, crdb_region
FROM request_event_log
WHERE crdb_region = 'us-central';

-- =============================================================================
-- US-WEST REGIONAL CHANGEFEED
-- =============================================================================

CREATE CHANGEFEED
INTO 'kafka://kafka:9093?topic_name=request-events.us-west'
WITH
    initial_scan = 'no',
    key_column = 'request_id',
    unordered,
    kafka_sink_config = '{"RequiredAcks": "ONE"}',
    cursor = 'now()'
AS SELECT request_id, seq_num, action_state_link_id, status_id, 
          event_ts, actor, metadata, idempotency_key, crdb_region
FROM request_event_log
WHERE crdb_region = 'us-west';

-- =============================================================================
-- VERIFICATION & MANAGEMENT QUERIES
-- =============================================================================

-- List all active changefeeds
SELECT
    job_id,
    description,
    status,
    created,
    high_water_timestamp
FROM [SHOW CHANGEFEED JOBS]
WHERE status IN ('running', 'paused')
ORDER BY created DESC;

-- Check changefeed progress and lag
SELECT
    job_id,
    description,
    status,
    high_water_timestamp,
    (cluster_logical_timestamp() - high_water_timestamp::DECIMAL) / 1e9 AS lag_seconds
FROM [SHOW CHANGEFEED JOBS]
WHERE status = 'running'
ORDER BY lag_seconds DESC;

-- Pause a specific changefeed (replace <job_id>)
-- PAUSE JOB <job_id>;

-- Resume a paused changefeed
-- RESUME JOB <job_id>;

-- Cancel a changefeed (permanent)
-- CANCEL JOB <job_id>;

-- Verify event distribution across regions
SELECT
    crdb_region,
    COUNT(*) AS event_count
FROM request_event_log
GROUP BY crdb_region
ORDER BY crdb_region;

-- =============================================================================
-- NOTES
-- =============================================================================
--
-- 1. Optional Changefeed Options Explained:
--    - updated: Include row modification timestamp
--    - resolved = '10s': Emit progress timestamps every 10 seconds
--    - diff: Include before/after values for updates (useful for event updates)
--    - format = 'json': Use JSON encoding
--    - envelope = 'wrapped': Wrap payloads with metadata (key, value, topic, timestamp)
--
-- 2. Regional Filtering:
--    - WHERE crdb_region = '<region>' ensures only regional events flow
--    - request_event_log inherits crdb_region from request_info
--    - Each changefeed captures only events for its region
--    - Total: 3 changefeeds (1 table × 3 regions)
--
-- 3. Kafka Topic Naming:
--    - Pattern: request-events.<region>
--    - Example topics:
--      * request-events.us-east
--      * request-events.us-central
--      * request-events.us-west
--    - Regional consumers subscribe to their region's topic only
--
-- 4. Consumer Configuration:
--    - Each regional application instance subscribes to its region's topic
--    - Consumer group per region ensures message ordering
--    - Example us-east consumer:
--      * Topic: request-events.us-east
--      * Consumer group: request-events-consumer-us-east
--    - Each instance processes only its local region's events
--
-- 5. Migration from Global Changefeeds (Phase 1-2):
--    - Phase 1-2: CREATE CHANGEFEED FOR TABLE request_event_log
--                 INTO 'kafka://.../event-logs'  (no WHERE filter)
--    - Consumer group distributed partitions across all 3 regional instances
--    - Phase 3: Drop old global changefeed, create 3 regional changefeeds
--    - Update consumers to subscribe to regional topics only
--
-- 6. Performance Benefits:
--    - Lower latency (regional event processing)
--    - Higher throughput (parallel regional streams)
--    - Better resource utilization (each instance processes local events)
--    - Reduced network egress costs (events stay regional)
--    - No cross-region event processing
--
-- 7. Monitoring:
--    - Monitor changefeed lag via SHOW CHANGEFEED JOBS
--    - Alert on lag > 30 seconds
--    - Track Kafka consumer lag separately
--    - Monitor for changefeed failures (status != 'running')
--    - Verify event distribution is balanced across regions
--
-- 8. Disaster Recovery:
--    - Changefeeds resume from high_water_timestamp after restart
--    - No data loss unless underlying table data is lost
--    - Consider retaining Kafka messages for 7+ days for replay
--    - Test failover by pausing/resuming changefeeds
--
-- 9. Application Changes:
--    - Update Kafka consumer configuration to subscribe to regional topic
--    - Example appsettings.us-east.json:
--      ```json
--      {
--        "UseGeoPartitioning": true,
--        "KafkaBootstrap": "localhost:9093",
--        "KafkaTopic": "request-events.us-east",
--        "KafkaConsumerGroup": "request-events-consumer-us-east"
--      }
--      ```
--
-- 10. Production Kafka Setup:
--     - Current setup uses single Kafka instance (localhost:9093) for dev/demo
--     - For production, consider:
--       * Regional Kafka clusters for better latency and throughput
--       * Update kafka:// URLs to regional endpoints
--       * Regional consumers connect to local Kafka cluster
--     - Topics remain regionally partitioned in both scenarios
--
-- 11. Rollback Plan:
--     - To rollback to global changefeed:
--       1. CANCEL all 3 regional changefeeds
--       2. CREATE global changefeed (no WHERE filter)
--       3. Update consumers to subscribe to global topic
--       4. Restart consumer with global consumer group
