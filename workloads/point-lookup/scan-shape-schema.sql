DROP DATABASE IF EXISTS scan_shape;
CREATE DATABASE IF NOT EXISTS scan_shape;
USE scan_shape;

DROP TABLE IF EXISTS outbox;

CREATE TABLE outbox (
  id UUID NOT NULL DEFAULT gen_random_uuid(),

  aggregatetype STRING NOT NULL,
  aggregateid   STRING NOT NULL,
  type          STRING NOT NULL,
  "timestamp"   TIMESTAMP NOT NULL DEFAULT now(),

  is_published      BOOL NOT NULL DEFAULT false,
  publish_timestamp TIMESTAMP NULL,

  payload       STRING NULL,

  CONSTRAINT outbox_pkey PRIMARY KEY (id)
);

-- Covered partial index (index-only read possible)
CREATE INDEX idx_outbox_unpublished_id_cover_ts
ON outbox (id)
STORING (publish_timestamp)
WHERE is_published = false;

ALTER DEFAULT PRIVILEGES FOR ROLE pgb 
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO pgb;
