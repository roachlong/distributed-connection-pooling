-- Kafka Partition Coordination Schema
-- Enables dynamic partition assignment across multiple app instances
-- Guarantees exactly-one-consumer-per-partition using CockroachDB's SERIALIZABLE isolation

-- =============================================================================
-- Cleanup: Drop existing tables (uncomment to recreate from scratch)
-- =============================================================================
DROP TABLE IF EXISTS kafka_partition_assignment_history CASCADE;
DROP TABLE IF EXISTS kafka_partition_assignments CASCADE;
DROP TABLE IF EXISTS kafka_consumers CASCADE;
DROP TABLE IF EXISTS kafka_coordination_config CASCADE;
DROP FUNCTION IF EXISTS claim_partition(STRING, INT4, STRING, STRING);
DROP FUNCTION IF EXISTS release_partition(STRING, INT4, STRING, STRING);
DROP FUNCTION IF EXISTS initialize_topic_partitions(STRING, INT4);

-- =============================================================================
-- Core Tables
-- =============================================================================

CREATE TABLE IF NOT EXISTS kafka_partition_assignments (
    topic             STRING NOT NULL,
    partition_id      INT4 NOT NULL,

    -- Current assignment
    consumer_id       STRING NULL,           -- UUID of consuming instance
    consumer_hostname STRING NULL,           -- For debugging
    assigned_at       TIMESTAMPTZ NULL,      -- When this consumer took ownership
    last_heartbeat    TIMESTAMPTZ NULL,      -- Last successful heartbeat

    -- Health monitoring
    last_offset       INT8 NULL,             -- Last committed offset
    last_processed_at TIMESTAMPTZ NULL,      -- When last message was processed
    messages_processed INT8 DEFAULT 0,       -- Counter for this consumer's tenure

    -- Failover tracking
    previous_consumer STRING NULL,           -- Previous owner (for debugging)
    reassignment_count INT4 DEFAULT 0,       -- How many times this partition has been reassigned

    PRIMARY KEY (topic, partition_id)
) WITH (ttl_expire_after = '7 days', ttl_expiration_expression = 'last_processed_at', ttl_select_batch_size = 200);

-- Index for finding unassigned or stale partitions
CREATE INDEX IF NOT EXISTS idx_partition_health
ON kafka_partition_assignments (topic, last_heartbeat)
WHERE consumer_id IS NOT NULL;

-- Consumer instance registry (with TTL to clean up stale registrations)
CREATE TABLE IF NOT EXISTS kafka_consumers (
    consumer_id       STRING PRIMARY KEY,
    hostname          STRING NOT NULL,
    process_id        INT4 NOT NULL,
    started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_heartbeat    TIMESTAMPTZ NOT NULL DEFAULT now(),
    partition_capacity INT4 NOT NULL DEFAULT 8,  -- Max partitions this consumer can handle
    current_partitions INT4 NOT NULL DEFAULT 0,  -- Currently assigned partitions
    version           STRING NULL,               -- App version for rolling deploys

    -- Status tracking
    is_healthy        BOOL NOT NULL DEFAULT true,
    consecutive_failures INT4 DEFAULT 0
) WITH (ttl_expire_after = '7 days', ttl_expiration_expression = 'last_heartbeat', ttl_select_batch_size = 100);

-- Index for finding healthy consumers
CREATE INDEX IF NOT EXISTS idx_healthy_consumers
ON kafka_consumers (is_healthy, last_heartbeat DESC, current_partitions ASC);

-- Partition assignment history (for debugging, TTL based on assigned_at - keep 7 days)
CREATE TABLE IF NOT EXISTS kafka_partition_assignment_history (
    topic             STRING NOT NULL,
    partition_id      INT4 NOT NULL,
    consumer_id       STRING NOT NULL,
    assigned_at       TIMESTAMPTZ NOT NULL,
    released_at       TIMESTAMPTZ NULL,
    reason            STRING NULL,  -- 'heartbeat_timeout', 'lag_detected', 'graceful_shutdown', 'rebalance'
    messages_processed INT8 DEFAULT 0,

    PRIMARY KEY (topic, partition_id, assigned_at)
) WITH (ttl_expire_after = '7 days', ttl_expiration_expression = 'released_at', ttl_select_batch_size = 500);

-- Configuration table
CREATE TABLE IF NOT EXISTS kafka_coordination_config (
    config_key   STRING PRIMARY KEY,
    config_value STRING NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Insert default configuration
INSERT INTO kafka_coordination_config (config_key, config_value) VALUES
    ('heartbeat_timeout_seconds', '30'),     -- Consumer is dead if no heartbeat for 30s
    ('lag_threshold_messages', '10000'),     -- Consumer is slow if 10k messages behind
    ('rebalance_cooldown_seconds', '60'),    -- Wait 60s between rebalances
    ('max_partitions_per_consumer', '8')     -- Default max partitions per consumer
ON CONFLICT (config_key) DO NOTHING;

-- =============================================================================
-- Helper Functions
-- =============================================================================

-- Function to claim a partition (uses SERIALIZABLE isolation automatically)
CREATE OR REPLACE FUNCTION claim_partition(
    p_topic STRING,
    p_partition INT4,
    p_consumer_id STRING,
    p_hostname STRING
) RETURNS BOOL AS $$
DECLARE
    v_current_consumer STRING;
    v_last_heartbeat TIMESTAMPTZ;
    v_heartbeat_timeout INTERVAL;
BEGIN
    -- Get configuration
    SELECT (config_value || ' seconds')::INTERVAL INTO v_heartbeat_timeout
    FROM kafka_coordination_config
    WHERE config_key = 'heartbeat_timeout_seconds';

    -- Check current assignment
    SELECT consumer_id, last_heartbeat INTO v_current_consumer, v_last_heartbeat
    FROM kafka_partition_assignments
    WHERE topic = p_topic AND partition_id = p_partition
    FOR UPDATE;  -- Lock the row

    -- Partition is available if:
    -- 1. No consumer assigned, OR
    -- 2. Current consumer's heartbeat timed out
    IF v_current_consumer IS NULL OR
       (v_last_heartbeat IS NOT NULL AND now() - v_last_heartbeat > v_heartbeat_timeout) THEN

        -- Record previous consumer for history
        IF v_current_consumer IS NOT NULL THEN
            INSERT INTO kafka_partition_assignment_history
                (topic, partition_id, consumer_id, assigned_at, released_at, reason, messages_processed)
            SELECT topic, partition_id, consumer_id, assigned_at, now(),
                   'heartbeat_timeout', messages_processed
            FROM kafka_partition_assignments
            WHERE topic = p_topic AND partition_id = p_partition;

            -- Decrement previous consumer's partition count (they lost this partition due to timeout)
            UPDATE kafka_consumers
            SET current_partitions = GREATEST(current_partitions - 1, 0)
            WHERE consumer_id = v_current_consumer;
        END IF;

        -- Claim the partition
        UPDATE kafka_partition_assignments
        SET consumer_id = p_consumer_id,
            consumer_hostname = p_hostname,
            assigned_at = now(),
            last_heartbeat = now(),
            previous_consumer = v_current_consumer,
            reassignment_count = reassignment_count + 1,
            messages_processed = 0
        WHERE topic = p_topic AND partition_id = p_partition;

        -- Update new consumer's partition count
        UPDATE kafka_consumers
        SET current_partitions = current_partitions + 1
        WHERE consumer_id = p_consumer_id;

        RETURN true;
    END IF;

    RETURN false;
END;
$$ LANGUAGE plpgsql;

-- Function to release a partition (graceful shutdown)
CREATE OR REPLACE FUNCTION release_partition(
    p_topic STRING,
    p_partition INT4,
    p_consumer_id STRING,
    p_reason STRING
) RETURNS VOID AS $$
BEGIN
    -- Record in history
    INSERT INTO kafka_partition_assignment_history
        (topic, partition_id, consumer_id, assigned_at, released_at, reason, messages_processed)
    SELECT topic, partition_id, consumer_id, assigned_at, now(),
           p_reason, messages_processed
    FROM kafka_partition_assignments
    WHERE topic = p_topic
      AND partition_id = p_partition
      AND consumer_id = p_consumer_id;

    -- Clear assignment
    UPDATE kafka_partition_assignments
    SET consumer_id = NULL,
        consumer_hostname = NULL,
        last_heartbeat = NULL
    WHERE topic = p_topic
      AND partition_id = p_partition
      AND consumer_id = p_consumer_id;

    -- Update consumer's partition count
    UPDATE kafka_consumers
    SET current_partitions = current_partitions - 1
    WHERE consumer_id = p_consumer_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Initialize partition entries for a topic
-- =============================================================================

-- Run this once per topic to create partition records
-- Example: SELECT initialize_topic_partitions('request-events', 24);

CREATE OR REPLACE FUNCTION initialize_topic_partitions(
    p_topic STRING,
    p_partition_count INT4
) RETURNS VOID AS $$
BEGIN
    FOR i IN 0..(p_partition_count - 1) LOOP
        INSERT INTO kafka_partition_assignments (topic, partition_id)
        VALUES (p_topic, i)
        ON CONFLICT (topic, partition_id) DO NOTHING;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Monitoring Queries
-- =============================================================================

-- View current partition distribution
-- SELECT * FROM v_partition_distribution;
CREATE OR REPLACE VIEW v_partition_distribution AS
SELECT
    kpa.topic,
    kpa.partition_id,
    kpa.consumer_id,
    kpa.consumer_hostname,
    kpa.assigned_at,
    kpa.last_heartbeat,
    now() - kpa.last_heartbeat AS heartbeat_age,
    kpa.messages_processed,
    kpa.last_offset,
    kpa.reassignment_count,
    kc.is_healthy AS consumer_healthy
FROM kafka_partition_assignments kpa
LEFT JOIN kafka_consumers kc ON kpa.consumer_id = kc.consumer_id
ORDER BY kpa.topic, kpa.partition_id;

-- Find orphaned partitions (no consumer or dead consumer)
CREATE OR REPLACE VIEW v_orphaned_partitions AS
SELECT
    topic,
    partition_id,
    consumer_id,
    last_heartbeat,
    now() - last_heartbeat AS time_since_heartbeat
FROM kafka_partition_assignments
WHERE consumer_id IS NULL
   OR (last_heartbeat IS NOT NULL AND now() - last_heartbeat > INTERVAL '30 seconds')
ORDER BY topic, partition_id;

-- Consumer health overview
CREATE OR REPLACE VIEW v_consumer_health AS
SELECT
    kc.consumer_id,
    kc.hostname,
    kc.started_at,
    kc.last_heartbeat,
    now() - kc.last_heartbeat AS heartbeat_age,
    kc.current_partitions,
    kc.partition_capacity,
    kc.is_healthy,
    kc.consecutive_failures,
    COUNT(kpa.partition_id) AS actual_partition_count
FROM kafka_consumers kc
LEFT JOIN kafka_partition_assignments kpa ON kc.consumer_id = kpa.consumer_id
GROUP BY kc.consumer_id, kc.hostname, kc.started_at, kc.last_heartbeat,
         kc.current_partitions, kc.partition_capacity, kc.is_healthy, kc.consecutive_failures
ORDER BY kc.last_heartbeat DESC;
