DROP TABLE IF EXISTS events_jsonb CASCADE;
DROP TABLE IF EXISTS events_text CASCADE;
DROP TABLE IF EXISTS events_jsonb_status;
DROP TABLE IF EXISTS events_jsonb_archive;
DROP TABLE IF EXISTS events_text_status;
DROP TABLE IF EXISTS events_text_archive;

-- ---------------------------------------------------------
-- Enum type for event types
-- ---------------------------------------------------------
DROP TYPE IF EXISTS event_type_enum;
CREATE TYPE event_type_enum AS ENUM (
  'ROUTE_AUTHORIZATION',
  'SIGNAL_CLEAR',
  'SPEED_RESTRICTION',
  'TRACK_OUT_OF_SERVICE',
  'TRAIN_POSITION_UPDATE',
  'SWITCH_POSITION_CHANGE',
  'WORK_ZONE_PROTECTION',
  'CROSSING_FAILURE',
  'POWER_OUTAGE',
  'DISPATCH_NOTE'
);

-- ---------------------------------------------------------
-- Core tables: JSONB-backed events
-- ---------------------------------------------------------
CREATE TABLE events_jsonb (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload      JSONB NOT NULL,

  event_type   event_type_enum
    GENERATED ALWAYS AS ((payload->>'eventType')::event_type_enum) STORED,
  authority_id STRING
    GENERATED ALWAYS AS (payload->>'authorityId') STORED,
  train_id     STRING
    GENERATED ALWAYS AS ((payload->'train'->>'trainId')) STORED
);

CREATE INVERTED INDEX idx_events_jsonb_payload ON events_jsonb (payload);
CREATE INDEX idx_events_jsonb_event_type_created ON events_jsonb (event_type, created_at DESC);
CREATE INDEX idx_events_jsonb_authority ON events_jsonb (authority_id);

-- ---------------------------------------------------------
-- Core tables: TEXT-backed events (same logical shape)
-- ---------------------------------------------------------
CREATE TABLE events_text (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload      STRING NOT NULL,

  event_type   event_type_enum
    GENERATED ALWAYS AS (((payload::JSONB)->>'eventType')::event_type_enum) STORED,
  authority_id STRING
    GENERATED ALWAYS AS ((payload::JSONB)->>'authorityId') STORED,
  train_id     STRING
    GENERATED ALWAYS AS (((payload::JSONB)->'train'->>'trainId')) STORED
);

CREATE INDEX idx_events_text_event_type_created ON events_text (event_type, created_at DESC);
CREATE INDEX idx_events_text_authority ON events_text (authority_id);

-- ---------------------------------------------------------
-- Status + archive tables
-- ---------------------------------------------------------
CREATE TABLE events_jsonb_status (
  event_id     UUID PRIMARY KEY REFERENCES events_jsonb (id) ON DELETE CASCADE,
  status       STRING NOT NULL CHECK (status IN ('PENDING','PROCESSING','COMPLETE','FAILED')),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_events_jsonb_status_updated ON events_jsonb_status (status, updated_at);

CREATE TABLE events_jsonb_archive (
  id           UUID PRIMARY KEY,
  archived_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload      JSONB NOT NULL,
  event_type   event_type_enum,
  authority_id STRING,
  created_at   TIMESTAMPTZ,
  train_id     STRING
);

CREATE TABLE events_text_status (
  event_id     UUID PRIMARY KEY REFERENCES events_text (id) ON DELETE CASCADE,
  status       STRING NOT NULL CHECK (status IN ('PENDING','PROCESSING','COMPLETE','FAILED')),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_events_text_status_updated ON events_text_status (status, updated_at);

CREATE TABLE events_text_archive (
  id           UUID PRIMARY KEY,
  archived_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload      STRING NOT NULL,
  event_type   event_type_enum,
  authority_id STRING,
  created_at   TIMESTAMPTZ,
  train_id     STRING
);
