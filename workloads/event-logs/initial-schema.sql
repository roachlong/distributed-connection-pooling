-- Multi-region database setup, it's assumed below was applied when database was created:
-- ALTER DATABASE defaultdb PRIMARY REGION "us-east";
-- ALTER DATABASE defaultdb ADD REGION "us-central";
-- ALTER DATABASE defaultdb ADD REGION "us-west";
-- ALTER DATABASE defaultdb SURVIVE REGION FAILURE;

USE defaultdb;

-- Drop existing tables (from earlier iterations)
DROP TABLE IF EXISTS trade_info CASCADE;
DROP TABLE IF EXISTS request_account_link CASCADE;
DROP TABLE IF EXISTS account_info CASCADE;
DROP TABLE IF EXISTS request_info CASCADE;
DROP TABLE IF EXISTS request_event_log CASCADE;
DROP TABLE IF EXISTS request_status_head CASCADE;
DROP TABLE IF EXISTS request_status CASCADE;
DROP TABLE IF EXISTS request_action_state_link CASCADE;
DROP TABLE IF EXISTS request_state CASCADE;
DROP TABLE IF EXISTS request_action_type CASCADE;
DROP TABLE IF EXISTS request_type CASCADE;

-- ---------------------------------------------------------

-- Global master tables
CREATE TABLE request_type (
    request_type_id   INT4 PRIMARY KEY,
    request_type_code STRING NOT NULL UNIQUE,
    description       STRING NOT NULL
) LOCALITY GLOBAL;

CREATE TABLE request_action_type (
    action_type_id   INT4 PRIMARY KEY,
    action_code      STRING NOT NULL UNIQUE,
    description      STRING NOT NULL
) LOCALITY GLOBAL;

CREATE TABLE request_state (
    state_id         INT4 PRIMARY KEY,
    state_code       STRING NOT NULL UNIQUE,
    description      STRING NOT NULL
) LOCALITY GLOBAL;

CREATE TABLE request_action_state_link (
    action_state_link_id  INT8 PRIMARY KEY DEFAULT unique_rowid(),

    request_type_id    INT4 NOT NULL REFERENCES request_type (request_type_id),
    action_type_id     INT4 NOT NULL REFERENCES request_action_type (action_type_id),
    state_id           INT4 NOT NULL REFERENCES request_state (state_id),

    is_initial         BOOL  NOT NULL DEFAULT false,
    is_terminal        BOOL  NOT NULL DEFAULT false,
    sort_order         INT4  NOT NULL DEFAULT 0,

    UNIQUE (request_type_id, action_type_id, state_id)
) LOCALITY GLOBAL;

CREATE INDEX idx_rasl_by_request_action
ON request_action_state_link (request_type_id, action_type_id, sort_order)
STORING (state_id, is_initial, is_terminal);

CREATE TABLE request_status (
    status_id      INT4 PRIMARY KEY,
    status_code    STRING NOT NULL UNIQUE,  -- e.g. IN_PROGRESS, COMPLETE, FAILED
    description    STRING NOT NULL
) LOCALITY GLOBAL;

-- ---------------------------------------------------------

-- Geo-partitioned account_info
-- Accounts are long-lived, many requests can reference the same account.
CREATE TABLE account_info (
    account_id      UUID NOT NULL DEFAULT gen_random_uuid(),
    account_number  STRING NOT NULL,
    account_name    STRING NOT NULL,
    strategy        STRING NULL,
    base_currency   STRING NULL,

    -- Hash-based locality bucket [0..29] derived from account_id
    locality INT2 NOT NULL AS (
        mod(
            crc32ieee(account_id::BYTES),
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

    computed_region crdb_internal_region NOT VISIBLE NOT NULL AS (
        CASE
            WHEN mod(crc32ieee(account_id::BYTES), 30:::INT8)::INT2
                 IN (0,1,2,3,4,5,6,7,8,9)
                THEN 'us-east'::crdb_internal_region
            WHEN mod(crc32ieee(account_id::BYTES), 30:::INT8)::INT2
                 IN (10,11,12,13,14,15,16,17,18,19)
                THEN 'us-central'::crdb_internal_region
            ELSE
                'us-west'::crdb_internal_region
        END
    ) STORED,

    PRIMARY KEY (locality, account_id)
) LOCALITY REGIONAL BY ROW AS computed_region;

-- Useful index to look up by human-visible account_number
CREATE INDEX account_info_by_number
ON account_info (account_number)
STORING (account_name, strategy, base_currency);

-- ---------------------------------------------------------

-- Geo-partitioned request_info
-- Requests (e.g., portfolio rebalances) will be co-located with a primary account by copying its locality.
CREATE TABLE request_info (
    request_id          UUID NOT NULL DEFAULT gen_random_uuid(),
    request_type_id     INT4 NOT NULL REFERENCES request_type (request_type_id),
    primary_account_id  UUID NOT NULL,
    created_ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    requested_by        STRING NOT NULL,
    description         STRING NULL,
    target_effective_ts TIMESTAMPTZ NULL,

    -- request_status_id gives current coarse-grained lifecycle status
    request_status_id   INT4 NOT NULL REFERENCES request_status (status_id),

    -- locality copied from primary account's locality (app-level responsibility)
    locality INT2 NOT NULL
    CHECK (
        locality IN (
            0,1,2,3,4,5,6,7,8,9,
            10,11,12,13,14,15,16,17,18,19,
            20,21,22,23,24,25,26,27,28,29
        )
    ),

    computed_region crdb_internal_region NOT VISIBLE NOT NULL AS (
        CASE
            WHEN locality IN (0,1,2,3,4,5,6,7,8,9)        THEN 'us-east'::crdb_internal_region
            WHEN locality IN (10,11,12,13,14,15,16,17,18,19)
                                                         THEN 'us-central'::crdb_internal_region
            ELSE 'us-west'::crdb_internal_region
        END
    ) STORED,

    PRIMARY KEY (locality, request_id)
) LOCALITY REGIONAL BY ROW AS computed_region;

-- Optional: index to search requests by created_ts / request_type / status
CREATE INDEX request_info_search
ON request_info (created_ts DESC, request_type_id, request_status_id)
STORING (primary_account_id, requested_by);

-- ---------------------------------------------------------

-- Many-to-many: request_account_link
-- Any request can touch multiple accounts, and any account can appear in many requests.
-- but note that only the primary account is guaranteed to be co-located with the request info
CREATE TABLE request_account_link (
    request_id      UUID NOT NULL,
    account_id      UUID NOT NULL,
    role            STRING NULL,    -- e.g. 'SOURCE', 'DESTINATION', 'BENEFICIARY'
    allocation_pct  DECIMAL(5,2) NULL,

    PRIMARY KEY (request_id, account_id)
);

-- ---------------------------------------------------------

-- Geo-partitioned trade_info
-- Trades are tied to a single request, so they inherit the request’s locality.

CREATE TABLE trade_info (
    locality    INT2 NOT NULL,
    trade_id    UUID NOT NULL DEFAULT gen_random_uuid(),
    request_id  UUID NOT NULL,
    account_id  UUID NOT NULL,
    symbol      STRING NOT NULL,
    side        STRING NOT NULL,     -- 'BUY' / 'SELL'
    quantity    DECIMAL(20,4) NOT NULL,
    price       DECIMAL(20,4) NULL,
    currency    STRING NULL,
    status_id   INT4 NOT NULL REFERENCES request_status (status_id),
    created_ts  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_ts  TIMESTAMPTZ NULL,

    CHECK (
        locality IN (
            0,1,2,3,4,5,6,7,8,9,
            10,11,12,13,14,15,16,17,18,19,
            20,21,22,23,24,25,26,27,28,29
        )
    ),

    computed_region crdb_internal_region NOT VISIBLE NOT NULL AS (
        CASE
            WHEN locality IN (0,1,2,3,4,5,6,7,8,9)        THEN 'us-east'::crdb_internal_region
            WHEN locality IN (10,11,12,13,14,15,16,17,18,19)
                                                         THEN 'us-central'::crdb_internal_region
            ELSE 'us-west'::crdb_internal_region
        END
    ) STORED,

    PRIMARY KEY (locality, trade_id)
) LOCALITY REGIONAL BY ROW AS computed_region;

CREATE INDEX trade_info_by_request
ON trade_info (locality, request_id, created_ts DESC)
STORING (account_id, symbol, side, quantity, status_id);

-- ---------------------------------------------------------

-- Geo-partitioned request_event_log (append-only event stream)
-- locality is not computed from request_id — it’s passed in from the app, so it matches request_info and trade_info.
CREATE TABLE request_event_log (
    request_id          UUID NOT NULL,
    seq_num             INT8 NOT NULL,       -- monotonic per request_id

    action_state_link_id  INT8 NOT NULL
        REFERENCES request_action_state_link (action_state_link_id),

    status_id           INT4 NOT NULL
        REFERENCES request_status (status_id),

    event_ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor               STRING NULL,
    metadata            JSONB NULL,

    -- locality: copied from request_info.locality
    locality INT2 NOT NULL
    CHECK (
        locality IN (
            0,1,2,3,4,5,6,7,8,9,
            10,11,12,13,14,15,16,17,18,19,
            20,21,22,23,24,25,26,27,28,29
        )
    ),

    computed_region crdb_internal_region NOT VISIBLE NOT NULL AS (
        CASE
            WHEN locality IN (0,1,2,3,4,5,6,7,8,9)        THEN 'us-east'::crdb_internal_region
            WHEN locality IN (10,11,12,13,14,15,16,17,18,19)
                                                         THEN 'us-central'::crdb_internal_region
            ELSE 'us-west'::crdb_internal_region
        END
    ) STORED,

    CONSTRAINT request_event_log_pk
        PRIMARY KEY (locality, request_id, seq_num),

    idempotency_key     STRING NOT NULL,
    CONSTRAINT request_event_log_uk
        UNIQUE (request_id, action_state_link_id, idempotency_key)
) LOCALITY REGIONAL BY ROW AS computed_region;

-- Index for "latest event per request" patterns
CREATE INDEX request_event_log_by_request_desc
ON request_event_log (locality, request_id, seq_num DESC)
STORING (action_state_link_id, status_id, event_ts, actor, metadata);

-- Optional partial index for incomplete statuses (e.g. 1=PENDING, 2=IN_PROGRESS)
CREATE INDEX request_event_log_incomplete
ON request_event_log (locality, status_id, event_ts DESC)
STORING (action_state_link_id, actor, metadata)
WHERE status_id IN (1, 2);  -- PENDING, IN_PROGRESS


-- ---------------------------------------------------------

-- Helper request_status_head (fast current-state projection)
-- To quickly check current state, maintain this table synchronously in the same transaction as event inserts.
CREATE TABLE request_status_head (
    locality           INT2 NOT NULL,
    request_id         UUID NOT NULL,

    action_state_link_id  INT8 NOT NULL
        REFERENCES request_action_state_link (action_state_link_id),
    status_id          INT4 NOT NULL
        REFERENCES request_status (status_id),
    event_ts           TIMESTAMPTZ NOT NULL,
    seq_num            INT8 NOT NULL,

    computed_region crdb_internal_region NOT VISIBLE NOT NULL AS (
        CASE
            WHEN locality IN (0,1,2,3,4,5,6,7,8,9)        THEN 'us-east'::crdb_internal_region
            WHEN locality IN (10,11,12,13,14,15,16,17,18,19)
                                                         THEN 'us-central'::crdb_internal_region
            ELSE 'us-west'::crdb_internal_region
        END
    ) STORED,

    PRIMARY KEY (locality, request_id)
) LOCALITY REGIONAL BY ROW AS computed_region;

-- ---------------------------------------------------------

-- End of schema

-- ---------------------------------------------------------

-- Required stub for EF Core compatibility

CREATE FUNCTION pg_indexam_has_property(am_oid OID, prop STRING)
RETURNS BOOL
LANGUAGE SQL
AS $$
  -- EF just uses this for metadata; it doesn't affect correctness
  SELECT true
$$;
