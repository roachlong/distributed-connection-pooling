-- ---------------------------------------------------------
-- Rich synthetic seed data (JSONB) + mirror to TEXT
--   - Random eventType from enum
--   - Random authority/device IDs
--   - Random times, train IDs, directions
--   - Per-row random route segments, switches, circuitIds, confidence
-- ---------------------------------------------------------

INSERT INTO events_jsonb (payload)
SELECT
  jsonb_build_object(
    'eventType',
      (
        ARRAY[
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
        ]
      )[(1 + floor(random()*10))::INT],

    'authorityId', gen_random_uuid()::STRING,
    'deviceKey',   gen_random_uuid()::STRING,
    'state',       'NEW',
    'createdAt',   (clock_timestamp() - (random()*interval '21 days'))::STRING,

    'route', jsonb_build_object(
      'segments', segs.segments,
      'switches', sws.switches,
      'attributes', jsonb_build_object(
        'ALLOW_PASS',   true,
        'REQUIRES_ACK', false,
        'SLOW_ORDER',   false
      ),
      'signalId', 9001
    ),

    'metrics', jsonb_build_object(
      'flags', jsonb_build_object(
        'onTrack', (random() < 0.8),
        'fleeted', (random() < 0.2)
      ),
      'circuitIds', cir.circuit_ids,
      'confidence', 0.5 + random()/2.0   -- 0.5–1.0
    ),

    'train', jsonb_build_object(
      'trainId',
        'RR-' || (1 + floor(random()*99))::INT || '-' ||
        (10000 + floor(random()*90000))::INT || '-' ||
        to_char(current_date - (floor(random()*30))::INT, 'YYYYMMDD'),
      'withinLimits', (random() < 0.5),
      'direction',
        (
          ARRAY['NORTHBOUND','SOUTHBOUND','EASTBOUND','WESTBOUND']
        )[ ((g.n + 1) % 4) + 1 ]      -- depends on g
    ),

    'meta', jsonb_build_object(
      'userId',       'operator01',
      'logicalPos',   'SYS01',
      'sourceSystem', 'SIMULATOR'
    )
  )
FROM
  generate_series(1, 20000) AS g(n)

  -- per-row "random-ish" segments, derived from g.n and inner index
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object(
               'id',
                 1000 + ((g.n * 10 + s.idx * 13) % 500),
               'direction',
                 (
                   ARRAY['NORTHBOUND','SOUTHBOUND','EASTBOUND','WESTBOUND']
                 )[ ((g.n + s.idx) % 4) + 1 ],
               'trackSections',
                 (
                   SELECT jsonb_agg(
                            2000 + ((g.n * 7 + ts.idx * 17) % 200)
                          )
                   FROM generate_series(1, 3) AS ts(idx)
                 )
             )
           ) AS segments
    FROM generate_series(1, 3) AS s(idx)
  ) AS segs

  -- per-row "random-ish" switches
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object(
               'id',
                 3000 + ((g.n * 5 + sw.idx * 11) % 500),
               'position',
                 (
                   ARRAY['NORMAL','REVERSE']
                 )[ ((g.n + sw.idx) % 2) + 1 ]
             )
           ) AS switches
    FROM generate_series(1, 2) AS sw(idx)
  ) AS sws

  -- per-row "random-ish" circuitIds
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(
             7000 + ((g.n * 3 + c.idx * 19) % 1000)
           ) AS circuit_ids
    FROM generate_series(1, 4) AS c(idx)
  ) AS cir;

-- -------------------------------------------------------------------
-- Mirror JSONB docs into manual-JSONB table
--   - keep id / created_at
--   - copy payload as-is
--   - derive event_type / authority_id / train_id from payload
-- -------------------------------------------------------------------
INSERT INTO events_jsonb_manual (
  id,
  created_at,
  payload,
  event_type,
  authority_id,
  train_id
)
SELECT
  e.id,
  e.created_at,
  e.payload,
  (e.payload->>'eventType')::event_type_enum        AS event_type,
  e.payload->>'authorityId'                         AS authority_id,
  e.payload->'train'->>'trainId'                    AS train_id
FROM events_jsonb AS e
LEFT JOIN events_jsonb_manual AS m
  ON m.id = e.id
WHERE m.id IS NULL;

-- Mirror JSONB docs into TEXT table
INSERT INTO events_text (payload)
SELECT payload::STRING FROM events_jsonb;

-- JSONB side
INSERT INTO events_jsonb_status (event_id, status)
SELECT e.id, 'PENDING'
FROM events_jsonb e
LEFT JOIN events_jsonb_status s ON s.event_id = e.id
WHERE s.event_id IS NULL;

-- JSONB manual
INSERT INTO events_jsonb_manual_status (event_id, status)
SELECT e.id, 'PENDING'
FROM events_jsonb_manual e
LEFT JOIN events_jsonb_manual_status s ON s.event_id = e.id
WHERE s.event_id IS NULL;

-- TEXT side
INSERT INTO events_text_status (event_id, status)
SELECT e.id, 'PENDING'
FROM events_text e
LEFT JOIN events_text_status s ON s.event_id = e.id
WHERE s.event_id IS NULL;