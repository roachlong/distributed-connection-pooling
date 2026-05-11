-- Initial Event Logs Schema (Non-Geo-Partitioned)
-- This is the starting point before implementing multi-region abstractions
-- Only account_info uses manual hash-based partitioning for demonstration

USE defaultdb;

-- Drop existing tables (from earlier iterations)
DROP TABLE IF EXISTS trade_info CASCADE;
DROP TABLE IF EXISTS request_account_link CASCADE;
DROP TABLE IF EXISTS request_status_head CASCADE;
DROP TABLE IF EXISTS request_event_log CASCADE;
DROP TABLE IF EXISTS request_info CASCADE;
DROP TABLE IF EXISTS account_info CASCADE;
DROP TABLE IF EXISTS request_action_state_link CASCADE;
DROP TABLE IF EXISTS request_state CASCADE;
DROP TABLE IF EXISTS request_action_type CASCADE;
DROP TABLE IF EXISTS request_type CASCADE;
DROP TABLE IF EXISTS request_status CASCADE;

-- =============================================================================
-- PREREQUISITE: Database must NOT have multi-region configuration
-- =============================================================================
-- This schema uses manual PARTITION BY which is incompatible with multi-region.
--
-- To check if regions are configured:
--   SHOW REGIONS FROM DATABASE defaultdb;
--
-- If regions exist, run this first:
--   \i 00-cleanup-regions.sql
--
-- Or manually drop them in this order:
--   1. ALTER DATABASE defaultdb SURVIVE ZONE FAILURE;
--   2. ALTER DATABASE defaultdb DROP REGION "us-central";
--   3. ALTER DATABASE defaultdb DROP REGION "us-west";
--   4. ALTER DATABASE defaultdb DROP REGION "us-east";
-- =============================================================================

-- =============================================================================
-- CONFIGURATION TABLES (regular tables, not GLOBAL)
-- =============================================================================

CREATE TABLE request_type (
    request_type_id   INT4 PRIMARY KEY,
    request_type_code STRING NOT NULL UNIQUE,
    description       STRING NOT NULL
);

CREATE TABLE request_action_type (
    action_type_id   INT4 PRIMARY KEY,
    action_code      STRING NOT NULL UNIQUE,
    description      STRING NOT NULL
);

CREATE TABLE request_state (
    state_id         INT4 PRIMARY KEY,
    state_code       STRING NOT NULL UNIQUE,
    description      STRING NOT NULL
);

CREATE TABLE request_action_state_link (
    action_state_link_id  INT8 PRIMARY KEY DEFAULT unique_rowid(),

    request_type_id    INT4 NOT NULL REFERENCES request_type (request_type_id),
    action_type_id     INT4 NOT NULL REFERENCES request_action_type (action_type_id),
    state_id           INT4 NOT NULL REFERENCES request_state (state_id),

    is_initial         BOOL  NOT NULL DEFAULT false,
    is_terminal        BOOL  NOT NULL DEFAULT false,
    sort_order         INT4  NOT NULL DEFAULT 0,

    UNIQUE (request_type_id, action_type_id, state_id)
);

CREATE INDEX idx_rasl_by_request_action
ON request_action_state_link (request_type_id, action_type_id, sort_order)
STORING (state_id, is_initial, is_terminal);

CREATE TABLE request_status (
    status_id      INT4 PRIMARY KEY,
    status_code    STRING NOT NULL UNIQUE,  -- IN_PROGRESS, COMPLETE, FAILED, etc.
    description    STRING NOT NULL
);

-- =============================================================================
-- ACCOUNT_INFO - Manually partitioned using computed locality hash
-- =============================================================================
-- Demonstrates hash-based manual partitioning WITHOUT multi-region abstractions
-- locality is auto-calculated from account_number (no UUID dependency)

CREATE TABLE account_info (
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

    CONSTRAINT pk_account_info PRIMARY KEY (locality, account_number)
) PARTITION BY LIST (locality) (
    PARTITION us_east VALUES IN ((0), (1), (2), (3), (4), (5), (6), (7), (8), (9)),
    PARTITION us_central VALUES IN ((10), (11), (12), (13), (14), (15), (16), (17), (18), (19)),
    PARTITION us_west VALUES IN ((20), (21), (22), (23), (24), (25), (26), (27), (28), (29))
);

-- Configure zone placement for each partition (replicate across regions, lease preference per partition)
ALTER PARTITION us_east OF INDEX account_info@pk_account_info CONFIGURE ZONE USING
    num_replicas = 5,
    constraints = '{+region=us-east: 1, +region=us-central: 1, +region=us-west: 1}',
    lease_preferences = '[[+region=us-east], [+region=us-central], [+region=us-west]]';

ALTER PARTITION us_central OF INDEX account_info@pk_account_info CONFIGURE ZONE USING
    num_replicas = 5,
    constraints = '{+region=us-east: 1, +region=us-central: 1, +region=us-west: 1}',
    lease_preferences = '[[+region=us-central], [+region=us-east], [+region=us-west]]';

ALTER PARTITION us_west OF INDEX account_info@pk_account_info CONFIGURE ZONE USING
    num_replicas = 5,
    constraints = '{+region=us-east: 1, +region=us-central: 1, +region=us-west: 1}',
    lease_preferences = '[[+region=us-west], [+region=us-central], [+region=us-east]]';

CREATE INDEX account_info_by_number
ON account_info (account_number)
STORING (account_name, strategy, base_currency);

-- =============================================================================
-- REQUEST_INFO - Regular table (not REGIONAL BY ROW)
-- =============================================================================

CREATE TABLE request_info (
    request_id          UUID NOT NULL DEFAULT gen_random_uuid(),
    request_type_id     INT4 NOT NULL REFERENCES request_type (request_type_id),
    primary_account_number  STRING NOT NULL,
    created_ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    requested_by        STRING NOT NULL,
    description         STRING NULL,
    target_effective_ts TIMESTAMPTZ NULL,
    request_status_id   INT4 NOT NULL REFERENCES request_status (status_id),

    PRIMARY KEY (request_id)
);

CREATE INDEX request_info_search
ON request_info (created_ts DESC, request_type_id, request_status_id)
STORING (primary_account_number, requested_by);

-- =============================================================================
-- REQUEST_ACCOUNT_LINK - Many-to-many link
-- =============================================================================

CREATE TABLE request_account_link (
    request_id      UUID NOT NULL,
    account_number  STRING NOT NULL,
    role            STRING NULL,
    allocation_pct  DECIMAL(5,2) NULL,

    PRIMARY KEY (request_id, account_number)
);

-- =============================================================================
-- REQUEST_EVENT_LOG - Append-only event stream
-- =============================================================================

CREATE TABLE request_event_log (
    request_id          UUID NOT NULL,
    seq_num             INT8 NOT NULL,

    action_state_link_id  INT8 NOT NULL
        REFERENCES request_action_state_link (action_state_link_id),

    status_id           INT4 NOT NULL
        REFERENCES request_status (status_id),

    event_ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor               STRING NULL,
    metadata            JSONB NULL,

    idempotency_key     STRING NOT NULL,

    CONSTRAINT request_event_log_pk
        PRIMARY KEY (request_id, seq_num),

    CONSTRAINT request_event_log_uk
        UNIQUE (request_id, action_state_link_id, idempotency_key)
);

CREATE INDEX request_event_log_by_request_desc
ON request_event_log (request_id, seq_num DESC)
STORING (action_state_link_id, status_id, event_ts, actor, metadata);

CREATE INDEX request_event_log_incomplete
ON request_event_log (status_id, event_ts DESC)
STORING (action_state_link_id, actor, metadata)
WHERE status_id IN (1, 2);  -- Adjust based on your status IDs for PENDING, IN_PROGRESS

-- =============================================================================
-- REQUEST_STATUS_HEAD - Current state projection
-- =============================================================================

CREATE TABLE request_status_head (
    request_id         UUID NOT NULL,

    action_state_link_id  INT8 NOT NULL
        REFERENCES request_action_state_link (action_state_link_id),
    status_id          INT4 NOT NULL
        REFERENCES request_status (status_id),
    event_ts           TIMESTAMPTZ NOT NULL,
    seq_num            INT8 NOT NULL,

    PRIMARY KEY (request_id)
);

-- =============================================================================
-- TRADE_INFO - Generated instructions
-- =============================================================================

CREATE TABLE trade_info (
    trade_id    UUID NOT NULL DEFAULT gen_random_uuid(),
    request_id  UUID NOT NULL,
    account_number  STRING NOT NULL,
    symbol      STRING NOT NULL,
    side        STRING NOT NULL,     -- 'BUY' / 'SELL'
    quantity    DECIMAL(20,4) NOT NULL,
    price       DECIMAL(20,4) NULL,
    currency    STRING NULL,
    status_id   INT4 NOT NULL REFERENCES request_status (status_id),
    created_ts  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_ts  TIMESTAMPTZ NULL,

    PRIMARY KEY (trade_id)
);

CREATE INDEX trade_info_by_request
ON trade_info (request_id, created_ts DESC)
STORING (account_number, symbol, side, quantity, status_id);

CREATE INDEX trade_info_by_account
ON trade_info (account_number, created_ts DESC)
STORING (symbol, side, quantity, status_id);

-- =============================================================================
-- TRIGGER: Update request_status_head from request_event_log
-- =============================================================================

CREATE OR REPLACE FUNCTION update_request_status_head()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO request_status_head (
        request_id,
        action_state_link_id,
        status_id,
        event_ts,
        seq_num
    )
    VALUES (
        (NEW).request_id,
        (NEW).action_state_link_id,
        (NEW).status_id,
        (NEW).event_ts,
        (NEW).seq_num
    )
    ON CONFLICT (request_id) DO UPDATE SET
        action_state_link_id = EXCLUDED.action_state_link_id,
        status_id = EXCLUDED.status_id,
        event_ts = EXCLUDED.event_ts,
        seq_num = EXCLUDED.seq_num
    WHERE EXCLUDED.seq_num > request_status_head.seq_num;

    RETURN (NEW);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_status_head
    AFTER INSERT ON request_event_log
    FOR EACH ROW
    EXECUTE FUNCTION update_request_status_head();

-- =============================================================================
-- EF Core Compatibility Stub
-- =============================================================================

CREATE OR REPLACE FUNCTION pg_indexam_has_property(am_oid OID, prop STRING)
RETURNS BOOL
LANGUAGE SQL
AS $$
  SELECT true
$$;
