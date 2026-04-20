-- =============================================================================
-- Cleanup Script - Reset all workload data
-- =============================================================================

-- Drop the trigger first to prevent it from firing during cleanup
DROP TRIGGER IF EXISTS trg_update_status_head ON request_event_log;

-- Truncate all workload tables (preserves structure, removes data)
TRUNCATE TABLE request_status_head CASCADE;
TRUNCATE TABLE request_event_log CASCADE;
TRUNCATE TABLE request_account_link CASCADE;
TRUNCATE TABLE request_info CASCADE;
TRUNCATE TABLE trade_info CASCADE;

-- Optional: Also truncate account_info if you want to reload accounts
-- TRUNCATE TABLE account_info CASCADE;

-- Verify cleanup
SELECT 'request_status_head' as table_name, COUNT(*) as count FROM request_status_head
UNION ALL
SELECT 'request_event_log', COUNT(*) FROM request_event_log
UNION ALL
SELECT 'request_info', COUNT(*) FROM request_info
UNION ALL
SELECT 'request_account_link', COUNT(*) FROM request_account_link
UNION ALL
SELECT 'trade_info', COUNT(*) FROM trade_info
UNION ALL
SELECT 'account_info', COUNT(*) FROM account_info;

-- Recreate the trigger (with correct CockroachDB syntax)
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

-- Confirm trigger exists
SELECT
    trigger_name,
    event_object_table,
    action_statement
FROM information_schema.triggers
WHERE event_object_table = 'request_event_log';
