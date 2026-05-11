-- Populate Global Configuration Tables
-- Transactional data (accounts, requests, events, trades) will be loaded by applications

USE defaultdb;

-- =============================================================================
-- REQUEST_TYPE
-- =============================================================================

INSERT INTO request_type (request_type_id, request_type_code, description) VALUES
(1, 'ACCOUNT_ONBOARDING', 'New account onboarding and setup'),
(2, 'ACCOUNT_PROFILE_UPDATE', 'Update to account profile or investment preferences'),
(3, 'ACCOUNT_PERMISSION_CHANGE', 'Modify account permissions or authorized users'),
(4, 'ACCOUNT_CLOSE', 'Close or deactivate an account'),
(5, 'PORTFOLIO_REBALANCE_ADJUSTMENT', 'Adjust holdings due to rebalancing'),
(6, 'SERVICE_ENROLLMENT', 'Enroll account in a new service or product'),
(7, 'CONTACT_INFO_UPDATE', 'Update mailing address or contact preferences'),
(8, 'BENEFICIARY_CHANGE', 'Modify account beneficiary designations'),
(9, 'INVESTMENT_STRATEGY_CHANGE', 'Change investment strategy or risk profile'),
(10, 'ACCOUNT_LINK', 'Link multiple accounts (e.g., household relationship)');

-- =============================================================================
-- REQUEST_ACTION_TYPE
-- =============================================================================

INSERT INTO request_action_type (action_type_id, action_code, description) VALUES
(1, 'VALIDATE_REQUEST', 'Validate request data and business rules'),
(2, 'COLLECT_DOCUMENTS', 'Gather required documentation'),
(3, 'REVIEW_COMPLIANCE', 'Compliance and regulatory review'),
(4, 'APPROVE_REQUEST', 'Management or automated approval'),
(5, 'UPDATE_ACCOUNT', 'Apply changes to account records'),
(6, 'GENERATE_INSTRUCTIONS', 'Create operational instructions (trades, transfers)'),
(7, 'EXECUTE_INSTRUCTIONS', 'Execute generated instructions'),
(8, 'VERIFY_COMPLETION', 'Verify all steps completed successfully'),
(9, 'NOTIFY_CLIENT', 'Send notification to client'),
(10, 'ARCHIVE_REQUEST', 'Archive completed or cancelled request');

-- =============================================================================
-- REQUEST_STATE
-- =============================================================================

INSERT INTO request_state (state_id, state_code, description) VALUES
(1, 'RECEIVED', 'Request received, not yet processed'),
(2, 'UNDER_REVIEW', 'Request is being reviewed'),
(3, 'PENDING_APPROVAL', 'Awaiting approval'),
(4, 'PENDING_EXTERNAL_ACTION', 'Waiting for external party (client, vendor)'),
(5, 'APPROVED', 'Request has been approved'),
(6, 'REJECTED', 'Request was rejected'),
(7, 'IN_PROGRESS', 'Work is actively being performed'),
(8, 'COMPLETED', 'Step completed successfully'),
(9, 'FAILED', 'Step failed with errors'),
(10, 'CANCELLED', 'Request cancelled by client or system');

-- =============================================================================
-- REQUEST_ACTION_STATE_LINK
-- =============================================================================
-- Defines valid (request_type, action, state) combinations and workflow order

-- Account Onboarding workflow
INSERT INTO request_action_state_link
(request_type_id, action_type_id, state_id, is_initial, is_terminal, sort_order) VALUES
(1, 1, 1, true, false, 1),   -- VALIDATE_REQUEST -> RECEIVED (initial)
(1, 1, 7, false, false, 2),  -- VALIDATE_REQUEST -> IN_PROGRESS
(1, 1, 8, false, false, 3),  -- VALIDATE_REQUEST -> COMPLETED
(1, 2, 7, false, false, 4),  -- COLLECT_DOCUMENTS -> IN_PROGRESS
(1, 2, 8, false, false, 5),  -- COLLECT_DOCUMENTS -> COMPLETED
(1, 3, 7, false, false, 6),  -- REVIEW_COMPLIANCE -> IN_PROGRESS
(1, 3, 8, false, false, 7),  -- REVIEW_COMPLIANCE -> COMPLETED
(1, 4, 5, false, false, 8),  -- APPROVE_REQUEST -> APPROVED
(1, 5, 7, false, false, 9),  -- UPDATE_ACCOUNT -> IN_PROGRESS
(1, 5, 8, false, false, 10), -- UPDATE_ACCOUNT -> COMPLETED
(1, 9, 8, false, true, 11);  -- NOTIFY_CLIENT -> COMPLETED (terminal)

-- Account Profile Update workflow
INSERT INTO request_action_state_link
(request_type_id, action_type_id, state_id, is_initial, is_terminal, sort_order) VALUES
(2, 1, 1, true, false, 1),   -- VALIDATE_REQUEST -> RECEIVED
(2, 1, 8, false, false, 2),  -- VALIDATE_REQUEST -> COMPLETED
(2, 4, 5, false, false, 3),  -- APPROVE_REQUEST -> APPROVED
(2, 5, 7, false, false, 4),  -- UPDATE_ACCOUNT -> IN_PROGRESS
(2, 5, 8, false, false, 5),  -- UPDATE_ACCOUNT -> COMPLETED
(2, 9, 8, false, true, 6);   -- NOTIFY_CLIENT -> COMPLETED

-- Portfolio Rebalance workflow
INSERT INTO request_action_state_link
(request_type_id, action_type_id, state_id, is_initial, is_terminal, sort_order) VALUES
(5, 1, 1, true, false, 1),   -- VALIDATE_REQUEST -> RECEIVED
(5, 1, 8, false, false, 2),  -- VALIDATE_REQUEST -> COMPLETED
(5, 6, 7, false, false, 3),  -- GENERATE_INSTRUCTIONS -> IN_PROGRESS
(5, 6, 8, false, false, 4),  -- GENERATE_INSTRUCTIONS -> COMPLETED
(5, 7, 7, false, false, 5),  -- EXECUTE_INSTRUCTIONS -> IN_PROGRESS
(5, 7, 8, false, false, 6),  -- EXECUTE_INSTRUCTIONS -> COMPLETED
(5, 8, 8, false, true, 7);   -- VERIFY_COMPLETION -> COMPLETED

-- =============================================================================
-- REQUEST_STATUS
-- =============================================================================

INSERT INTO request_status (status_id, status_code, description) VALUES
(1, 'PENDING', 'Request is pending, not yet started'),
(2, 'IN_PROGRESS', 'Request is actively being processed'),
(3, 'COMPLETE', 'Request completed successfully'),
(4, 'FAILED', 'Request failed with errors'),
(5, 'CANCELLED', 'Request was cancelled');
