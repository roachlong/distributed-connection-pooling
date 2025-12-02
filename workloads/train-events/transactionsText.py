import psycopg
from psycopg.errors import SerializationFailure, OperationalError
import random
import time

class Transactionstext:

    def __init__(self, args: dict):
        # args is a dict of string passed with the --args flag
        # user passed a yaml/json, in python that's a dict object
        self.min_batch_size: int = int(args.get("min_batch_size", 10))
        self.max_batch_size: int = int(args.get("max_batch_size", 100))
        self.delay: int = int(args.get("delay", 100))
        self.txn_pooling: bool = bool(args.get("txn_pooling", False))

        # you can arbitrarily add any variables you want
        self.counter: int = 0



    def _random_batch_size(self) -> int:
        if self.max_batch_size <= self.min_batch_size:
            return self.min_batch_size
        return random.randint(self.min_batch_size, self.max_batch_size)
    


    def _exec(self, cur, sql, params=None):
        """
        Wrapper around cursor.execute() that always disables server-side
        prepared statements (prepare=False), which is required when using
        PgBouncer in transaction pooling mode.
        """
        if params is None:
            if self.txn_pooling:
                return cur.execute(sql, prepare=False)
            else:
                return cur.execute(sql)
        else:
            if self.txn_pooling:
                return cur.execute(sql, params, prepare=False)
            else:
                return cur.execute(sql, params)
      


    def _is_retryable_error(self, err: Exception) -> bool:
      # Cockroach retryable transaction errors are a subclass of SerializationFailure
      if isinstance(err, SerializationFailure):
          return True
      else:
          return False



    def _run_txn_with_retries(self, conn: psycopg.Connection, fn, max_retries: int = 5):
        """
        Run a transactional function `fn(conn)` with Cockroach-style retries.
        The function `fn` should:
          - set conn.autocommit = False
          - do its work
          - COMMIT on success
        Any retryable error will cause a retry of `fn` up to max_retries.
        """
        attempt = 0
        while True:
            try:
                # Make sure we're not starting in an aborted txn
                try:
                    conn.rollback()
                except Exception:
                    # If there's nothing to roll back or it fails, ignore
                    pass
                conn.autocommit = True  # reset to default before retry

                return fn(conn)
            except Exception as e:
                if not self._is_retryable_error(e) or attempt >= max_retries:
                    # Non-retryable or max attempts exceeded – re-raise
                    raise

                # Best effort: ensure we clean up before retry
                try:
                    conn.rollback()
                except Exception:
                    pass

                sleep_ms = (2 ** attempt) * 0.05  # 50ms, 100ms, 200ms, ...
                print(f"[retry] {fn.__name__} attempt {attempt+1} failed with {e}, retrying in {sleep_ms:.3f}s")
                time.sleep(sleep_ms)
                attempt += 1



    # the setup() function is executed only once
    # when a new executing thread is started.
    # Also, the function is a vector to receive the executing thread's unique id and the total thread count
    def setup(self, conn: psycopg.Connection, id: int, total_thread_count: int):
        self.id = id

        if self.txn_pooling:
            # 👇 Disable server-side prepared statements for PgBouncer transaction pooling
            try:
                conn.prepare_threshold = 0
            except Exception as e:
                print(f"Could not disable prepared statements: {e}")

        with conn.cursor() as cur:
            print(
                f"My thread ID is {id}. The total count of threads is {total_thread_count}"
            )
            print(self._exec(cur, "select version()").fetchone()[0])



    # the loop() function returns a list of functions
    # that dbworkload will execute, sequentially.
    # Once every func has been executed, loop() is re-evaluated.
    # This process continues until dbworkload exits.
    def loop(self):
        time.sleep(random.uniform(0.75, 1.25) * self.delay / 1000)
        return [self.add, self.process, self.archive]



    # conn is an instance of a psycopg connection object
    # setting autocommit=False to simulate explicit commit
    def add(self, conn: psycopg.Connection):
        self._run_txn_with_retries(conn, self._add_once)

    def _add_once(self, conn: psycopg.Connection):
        original_autocommit = conn.autocommit

        # Single event insert SQL (one row per execute) for TEXT payload
        insert_batch_sql = """
            WITH new_events AS (
                INSERT INTO events_text (payload)
                SELECT jsonb_build_object(
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
                    'segments',
                        (
                        SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id', 1000 + (floor(random()*500))::INT,
                                    'direction',
                                    (
                                        ARRAY['NORTHBOUND','SOUTHBOUND','EASTBOUND','WESTBOUND']
                                    )[(1 + floor(random()*4))::INT],
                                    'trackSections',
                                    (
                                        SELECT jsonb_agg(2000 + (floor(random()*200))::INT)
                                        FROM generate_series(1, 3)
                                    )
                                )
                              )
                        FROM generate_series(1, 3)
                        ),
                    'switches',
                        (
                        SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id', 3000 + (floor(random()*500))::INT,
                                    'position',
                                    (
                                        ARRAY['NORMAL','REVERSE']
                                    )[(1 + floor(random()*2))::INT]
                                )
                              )
                        FROM generate_series(1, 2)
                        ),
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
                    'circuitIds',
                        (
                        SELECT jsonb_agg(7000 + (floor(random()*1000))::INT)
                        FROM generate_series(1, 4)
                        ),
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
                        )[(1 + floor(random()*4))::INT]
                    ),

                    'meta', jsonb_build_object(
                    'userId',       'operator01',
                    'logicalPos',   'SYS01',
                    'sourceSystem', 'SIMULATOR'
                    )
                )::STRING
                FROM generate_series(1, %s)
                RETURNING id
            )
            SELECT id FROM new_events;
        """

        # Second statement: insert one status row per new id
        insert_status_sql = """
            INSERT INTO events_text_status (event_id, status)
            SELECT unnest(%s::uuid[]), 'PENDING';
        """

        try:
            conn.autocommit = False
            batch_size = self._random_batch_size()

            with conn.cursor() as cur:
                # Statement 1: batch insert events, get ids
                self._exec(cur, insert_batch_sql, (batch_size,))
                rows = cur.fetchall()
                event_ids = [r[0] for r in rows]

                if not event_ids:
                    conn.commit()
                    return

                # simulate a tiny app think-time
                time.sleep(random.uniform(0.01, 0.05))

                # Statement 2: insert corresponding status rows in bulk
                self._exec(cur, insert_status_sql, (event_ids,))

            conn.commit()
        except Exception as e:
            print(f"Error occurred in add: {e}")
            conn.rollback()
            raise
        finally:
            conn.autocommit = original_autocommit



    # conn is an instance of a psycopg connection object
    # setting autocommit=False to simulate explicit commit
    def process(self, conn: psycopg.Connection):
        self._run_txn_with_retries(conn, self._process_once)

    def _process_once(self, conn: psycopg.Connection):
        original_autocommit = conn.autocommit
        try:
            conn.autocommit = False
            with conn.cursor() as cur:
                # 1) Pick candidates (FOR UPDATE) – PENDING or PROCESSING
                batch_size = self._random_batch_size()
                select_sql = """
                    SELECT event_id
                    FROM events_text_status
                    WHERE status IN ('PENDING','PROCESSING')
                    ORDER BY updated_at
                    LIMIT %s
                    FOR UPDATE SKIP LOCKED
                """
                self._exec(cur, select_sql, (batch_size,))
                rows = cur.fetchall()
                candidate_ids = [r[0] for r in rows]

                if not candidate_ids:
                    # Nothing to do for this txn
                    conn.commit()
                    return

                # 2) Update statuses for those candidates
                status_sql = """
                    UPDATE events_text_status AS s
                    SET status = CASE
                                   WHEN random() < 0.6 THEN 'PROCESSING'
                                   WHEN random() < 0.9 THEN 'COMPLETE'
                                   ELSE 'FAILED'
                                 END,
                        updated_at = now()
                    WHERE s.event_id = ANY(%s)
                """
                self._exec(cur, status_sql, (candidate_ids,))

                # Simulate some app logic delay
                time.sleep(random.uniform(0.01, 0.05))

                # 3) Update event payloads for those same candidates
                events_sql = """
                    UPDATE events_text AS e
                    SET payload = jsonb_set(
                                    jsonb_set(
                                      (payload::JSONB),
                                      '{metrics,flags,fleeted}',
                                      to_jsonb((random() < 0.5))
                                    ),
                                    '{state}',
                                    to_jsonb(
                                      (ARRAY['NEW','QUEUED','IN_PROGRESS','APPLIED','CANCELLED'])[
                                        (1 + floor(random()*5))::INT
                                      ]
                                    )
                                  )::STRING
                    WHERE e.id = ANY(%s)
                """
                self._exec(cur, events_sql, (candidate_ids,))

            conn.commit()
        except Exception as e:
            print(f"Error occurred in process: {e}")
            conn.rollback()
            raise
        finally:
            conn.autocommit = original_autocommit



    # conn is an instance of a psycopg connection object
    # setting autocommit=False to simulate explicit commit
    def archive(self, conn: psycopg.Connection):
        self._run_txn_with_retries(conn, self._archive_once)

    def _archive_once(self, conn: psycopg.Connection):
        original_autocommit = conn.autocommit
        try:
            conn.autocommit = False
            with conn.cursor() as cur:
                batch_size = self._random_batch_size()

                # 1) Pick COMPLETE candidates
                select_sql = """
                    SELECT event_id
                    FROM events_text_status
                    WHERE status IN ('COMPLETE')
                    ORDER BY updated_at
                    LIMIT %s
                    FOR UPDATE SKIP LOCKED
                """
                self._exec(cur, select_sql, (batch_size,))
                rows = cur.fetchall()
                candidate_ids = [r[0] for r in rows]

                if not candidate_ids:
                    conn.commit()
                    return

                # 2) Insert into archive
                insert_archive_sql = """
                    INSERT INTO events_text_archive (id, payload, event_type, authority_id, created_at, train_id)
                    SELECT id, payload, event_type, authority_id, created_at, train_id
                    FROM events_text
                    WHERE id = ANY(%s)
                """
                self._exec(cur, insert_archive_sql, (candidate_ids,))

                # Simulate some app logic delay
                time.sleep(random.uniform(0.01, 0.05))

                # 3) Delete from main table
                delete_events_sql = """
                    DELETE FROM events_text
                    WHERE id = ANY(%s)
                """
                self._exec(cur, delete_events_sql, (candidate_ids,))

                # 4) Delete from status table
                delete_status_sql = """
                    DELETE FROM events_text_status
                    WHERE event_id = ANY(%s)
                """
                self._exec(cur, delete_status_sql, (candidate_ids,))

            conn.commit()
        except Exception as e:
            print(f"Error occurred in archive: {e}")
            conn.rollback()
            raise
        finally:
            conn.autocommit = original_autocommit
