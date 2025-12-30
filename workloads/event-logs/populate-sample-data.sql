USE defaultdb;

------------------------------------------------------------
-- 0. Clean up (optional if reseeding an existing DB)
------------------------------------------------------------

-- Comment these out if you want to preserve data.
TRUNCATE TABLE request_status_head CASCADE;
TRUNCATE TABLE request_event_log CASCADE;
TRUNCATE TABLE trade_info CASCADE;
TRUNCATE TABLE request_account_link CASCADE;
TRUNCATE TABLE request_info CASCADE;
TRUNCATE TABLE account_info CASCADE;
TRUNCATE TABLE request_action_state_link CASCADE;
TRUNCATE TABLE request_state CASCADE;
TRUNCATE TABLE request_action_type CASCADE;
TRUNCATE TABLE request_type CASCADE;
TRUNCATE TABLE request_status CASCADE;

------------------------------------------------------------
-- 1. Global master data
------------------------------------------------------------

-- 1.1 request_status: align with partial index (1=PENDING, 2=IN_PROGRESS)
INSERT INTO request_status (status_id, status_code, description)
VALUES
    (1, 'PENDING',    'Request is new and pending action'),
    (2, 'IN_PROGRESS','Request is in progress'),
    (3, 'COMPLETE',   'Request completed successfully'),
    (4, 'FAILED',     'Request failed'),
    (5, 'CANCELLED',  'Request was cancelled')
ON CONFLICT (status_id) DO NOTHING;

-- 1.2 request_type (account-management oriented)
INSERT INTO request_type (request_type_id, request_type_code, description)
VALUES
    (1, 'ACCOUNT_ONBOARDING',        'Onboard a new account'),
    (2, 'ACCOUNT_PROFILE_UPDATE',    'Update account profile or settings'),
    (3, 'ACCOUNT_PERMISSION_CHANGE', 'Change account permissions / entitlements'),
    (4, 'ACCOUNT_CLOSE',             'Close an existing account')
ON CONFLICT (request_type_id) DO NOTHING;

-- Add synthetic account-management types for variety
INSERT INTO request_type (request_type_id, request_type_code, description)
SELECT
    t,
    'ACCOUNT_MGMT_TYPE_' || lpad(t::STRING, 2, '0'),
    'Synthetic account management type ' || t::STRING
FROM generate_series(5, 20) AS t
ON CONFLICT (request_type_id) DO NOTHING;

-- 1.3 request_action_type
INSERT INTO request_action_type (action_type_id, action_code, description)
VALUES
    (1, 'VALIDATE_REQUEST',     'Validate incoming request'),
    (2, 'COLLECT_DOCUMENTS',    'Collect required documentation'),
    (3, 'APPLY_CHANGES',        'Apply changes to account records'),
    (4, 'NOTIFY_STAKEHOLDERS',  'Notify stakeholders of changes')
ON CONFLICT (action_type_id) DO NOTHING;

-- Add synthetic actions for variety
INSERT INTO request_action_type (action_type_id, action_code, description)
SELECT
    a,
    'ACTION_' || lpad(a::STRING, 3, '0'),
    'Synthetic account workflow action ' || a::STRING
FROM generate_series(5, 24) AS a
ON CONFLICT (action_type_id) DO NOTHING;

-- 1.4 request_state
-- Core workflow-ish states
INSERT INTO request_state (state_id, state_code, description)
VALUES
    (1, 'RECEIVED',          'Request received'),
    (2, 'UNDER_REVIEW',      'Request is under review'),
    (3, 'PENDING_APPROVAL',  'Waiting on approval'),
    (4, 'APPLYING_CHANGES',  'Applying changes to accounts'),
    (5, 'AWAITING_CONFIRM',  'Awaiting downstream confirmations'),
    (6, 'COMPLETED',         'Workflow completed')
ON CONFLICT (state_id) DO NOTHING;

-- Synthetic states for width / variety (up to 200)
INSERT INTO request_state (state_id, state_code, description)
SELECT
    s,
    'STATE_' || lpad(s::STRING, 3, '0'),
    'Synthetic workflow state ' || s::STRING
FROM generate_series(7, 200) AS s
ON CONFLICT (state_id) DO NOTHING;

------------------------------------------------------------
-- 2. request_action_state_link
-- 2.1 Core “canonical” chains for the first 4 request types
--     These are used by the event seeding logic.
------------------------------------------------------------

INSERT INTO request_action_state_link (
    action_state_link_id,
    request_type_id,
    action_type_id,
    state_id,
    is_initial,
    is_terminal,
    sort_order
)
VALUES
    -- ACCOUNT_ONBOARDING (1)
    (1001, 1, 1, 1, true,  false, 10),  -- VALIDATE_REQUEST -> RECEIVED
    (1002, 1, 3, 4, false, false, 20),  -- APPLY_CHANGES   -> APPLYING_CHANGES
    (1003, 1, 4, 6, false, true,  30),  -- NOTIFY_STAKEHOLDERS -> COMPLETED

    -- ACCOUNT_PROFILE_UPDATE (2)
    (2001, 2, 1, 1, true,  false, 10),
    (2002, 2, 3, 4, false, false, 20),
    (2003, 2, 4, 6, false, true,  30),

    -- ACCOUNT_PERMISSION_CHANGE (3)
    (3001, 3, 1, 1, true,  false, 10),
    (3002, 3, 3, 3, false, false, 20),
    (3003, 3, 4, 6, false, true,  30),

    -- ACCOUNT_CLOSE (4)
    (4001, 4, 1, 1, true,  false, 10),
    (4002, 4, 3, 3, false, false, 20),
    (4003, 4, 4, 6, false, true,  30)
ON CONFLICT (action_state_link_id) DO NOTHING;

------------------------------------------------------------
-- 2.2 Synthetic breadth: thousands of additional combos
--     Only for request_type_id >= 5 (to avoid conflicting with the core entries)
------------------------------------------------------------

INSERT INTO request_action_state_link (
    request_type_id,
    action_type_id,
    state_id,
    is_initial,
    is_terminal,
    sort_order
)
SELECT
    rt.request_type_id,
    at.action_type_id,
    st.state_id,
    -- Make some states initial / terminal in a deterministic way
    (st.state_id % 10 = 1) AS is_initial,
    (st.state_id % 10 = 0) AS is_terminal,
    st.state_id AS sort_order
FROM request_type rt
JOIN request_action_type at ON rt.request_type_id >= 5
JOIN request_state st ON st.state_id >= 7 AND st.state_id <= 200
WHERE rt.request_type_id >= 5
  AND at.action_type_id BETWEEN 1 AND 24
  -- Throttle the combinations a bit (optional)
  AND (st.state_id % 5) = (at.action_type_id % 5);

-- This will typically yield many thousands of rows in request_action_state_link.

------------------------------------------------------------
-- 3. account_info (~10,000 accounts)
-- locality & computed_region are computed by the table definition
------------------------------------------------------------

-- Tune account count here
WITH RECURSIVE nums AS (
  SELECT 1 AS g
  UNION ALL
  SELECT g + 1 FROM nums WHERE g < 10000
)
INSERT INTO account_info (
    account_number,
    account_name,
    strategy,
    base_currency
)
SELECT
    'ACCT-' || lpad(g::STRING, 8, '0') AS account_number,
    'Account ' || g::STRING AS account_name,
    CASE (g % 4)
        WHEN 0 THEN 'Growth'
        WHEN 1 THEN 'Income'
        WHEN 2 THEN 'Balanced'
        ELSE 'Aggressive'
    END AS strategy,
    CASE (g % 3)
        WHEN 0 THEN 'USD'
        WHEN 1 THEN 'EUR'
        ELSE 'GBP'
    END AS base_currency
FROM nums;

------------------------------------------------------------
-- 4. request_info (~1,000 requests)
-- locality is copied from account_info.locality
------------------------------------------------------------

WITH accounts AS (
    SELECT
        account_id,
        locality,
        row_number() OVER () AS rn
    FROM account_info
)
INSERT INTO request_info (
    request_type_id,
    primary_account_id,
    created_ts,
    requested_by,
    description,
    target_effective_ts,
    request_status_id,
    locality
)
SELECT
    ((a.rn - 1) % 20) + 1 AS request_type_id,        -- cycle through 1..20
    a.account_id AS primary_account_id,
    now() - ((random() * 30)::INT)::STRING::INTERVAL AS created_ts,
    'user_' || ((a.rn - 1) % 100)::STRING AS requested_by,
    'Seeded request #' || a.rn::STRING AS description,
    now() + ((random() * 10)::INT)::STRING::INTERVAL AS target_effective_ts,
    1 AS request_status_id,          -- start as PENDING
    a.locality
FROM accounts a
WHERE a.rn <= 1000;                  -- tune request count here

------------------------------------------------------------
-- 5. request_account_link
-- Link each request to its primary account
------------------------------------------------------------

INSERT INTO request_account_link (request_id, account_id, role)
SELECT
    r.request_id,
    r.primary_account_id,
    'PRIMARY'
FROM request_info r;

------------------------------------------------------------
-- 6. trade_info (~5 trades per request => ~5,000 trades)
------------------------------------------------------------

INSERT INTO trade_info (
    locality,
    request_id,
    account_id,
    symbol,
    side,
    quantity,
    price,
    currency,
    status_id,
    created_ts,
    updated_ts
)
SELECT
    r.locality,
    r.request_id,
    r.primary_account_id AS account_id,
    'SYM' || lpad(t::STRING, 4, '0') AS symbol,
    CASE WHEN (t % 2) = 0 THEN 'BUY' ELSE 'SELL' END AS side,
    (10 + random() * 990)::DECIMAL(20,4) AS quantity,
    (50 + random() * 150)::DECIMAL(20,4) AS price,
    'USD' AS currency,
    CASE
        WHEN random() < 0.6 THEN 2      -- IN_PROGRESS
        ELSE 3                          -- COMPLETE
    END AS status_id,
    r.created_ts + (t * '3 minutes'::INTERVAL) AS created_ts,
    NULL::TIMESTAMPTZ AS updated_ts
FROM request_info r
JOIN generate_series(1, 5) AS t ON true;  -- trades per request

------------------------------------------------------------
-- 7. request_event_log (3 events per request)
-- Uses the canonical chains 1001..4003 for request_type_id 1..4.
-- For other request_type_ids, we still map into those 4 patterns
-- by folding into 1..4 to keep FK consistent and simple.
------------------------------------------------------------

WITH req AS (
    SELECT
        r.request_id,
        r.locality,
        CASE
            WHEN r.request_type_id BETWEEN 1 AND 4 THEN r.request_type_id
            ELSE ((r.request_type_id - 1) % 4) + 1
        END AS core_type_id,
        r.created_ts,
        -- Decide how many steps this request will have:
        -- ~20%: 1 step (PENDING only)
        -- ~30%: 2 steps (PENDING -> IN_PROGRESS)
        -- ~50%: 3 steps (PENDING -> IN_PROGRESS -> terminal)
        CASE
            WHEN random() < 0.20 THEN 1
            WHEN random() < 0.50 THEN 2
            ELSE 3
        END AS max_step
    FROM request_info r
),
steps AS (
    SELECT 1 AS seq_num
    UNION ALL SELECT 2
    UNION ALL SELECT 3
)
INSERT INTO request_event_log (
    request_id,
    seq_num,
    action_state_link_id,
    status_id,
    event_ts,
    actor,
    metadata,
    locality,
    idempotency_key
)
SELECT
    rq.request_id,
    s.seq_num,
    CASE rq.core_type_id
        WHEN 1 THEN
            CASE s.seq_num
                WHEN 1 THEN 1001
                WHEN 2 THEN 1002
                ELSE 1003
            END
        WHEN 2 THEN
            CASE s.seq_num
                WHEN 1 THEN 2001
                WHEN 2 THEN 2002
                ELSE 2003
            END
        WHEN 3 THEN
            CASE s.seq_num
                WHEN 1 THEN 3001
                WHEN 2 THEN 3002
                ELSE 3003
            END
        ELSE -- core_type_id = 4
            CASE s.seq_num
                WHEN 1 THEN 4001
                WHEN 2 THEN 4002
                ELSE 4003
            END
    END AS action_state_link_id,
    CASE
        WHEN s.seq_num = 1 THEN 1                    -- PENDING
        WHEN s.seq_num = 2 THEN 2                    -- IN_PROGRESS
        ELSE
            -- Terminal step: COMPLETE / FAILED / CANCELLED
            CASE
                WHEN random() < 0.70 THEN 3          -- COMPLETE
                WHEN random() < 0.85 THEN 4          -- FAILED
                ELSE 5                               -- CANCELLED
            END
    END AS status_id,
    rq.created_ts + (s.seq_num * '5 minutes'::INTERVAL) AS event_ts,
    'worker_' || (s.seq_num % 10)::STRING AS actor,
    jsonb_build_object('step', s.seq_num)::JSONB AS metadata,
    rq.locality,
    rq.request_id::STRING || '-' || s.seq_num::STRING AS idempotency_key
FROM req rq
JOIN steps s
  ON s.seq_num <= rq.max_step;

------------------------------------------------------------
-- 8. request_status_head (only non-terminal requests)
------------------------------------------------------------

DELETE FROM request_status_head where status_id <> -1;

INSERT INTO request_status_head (
    locality,
    request_id,
    action_state_link_id,
    status_id,
    event_ts,
    seq_num
)
WITH latest AS (
    SELECT
        e.locality,
        e.request_id,
        e.action_state_link_id,
        e.status_id,
        e.event_ts,
        e.seq_num,
        ROW_NUMBER() OVER (
            PARTITION BY e.request_id
            ORDER BY e.seq_num DESC
        ) AS rn
    FROM request_event_log e
)
SELECT
    locality,
    request_id,
    action_state_link_id,
    status_id,
    event_ts,
    seq_num
FROM latest
WHERE rn = 1
  AND status_id IN (1, 2);   -- only PENDING / IN_PROGRESS


------------------------------------------------------------
-- 9. Sync request_info.request_status_id with latest event status
------------------------------------------------------------

UPDATE request_info r
SET request_status_id = l.status_id
FROM (
    SELECT
        e.request_id,
        e.status_id
    FROM request_event_log e
    JOIN (
        SELECT request_id, max(seq_num) AS max_seq
        FROM request_event_log
        GROUP BY request_id
    ) m
    ON e.request_id = m.request_id
   AND e.seq_num    = m.max_seq
) AS l
WHERE r.request_id = l.request_id
  AND r.request_status_id <> l.status_id;
