import psycopg
from psycopg.errors import SerializationFailure
import random
import time


class Transactionsconcurrency:
    """
    Phase 2: Dispatcher/batch publish using SKIP LOCKED.

    Flow per cycle:
      - Insert N messages (one txn each) to keep pressure on the system
      - Dispatcher publishes up to dispatch_batch_size rows in one txn:
          SELECT ... FOR UPDATE SKIP LOCKED
          UPDATE ... RETURNING id, publish_timestamp

    This avoids point-lookup reads and prevents workers from blocking on the same rows.
    """

    def __init__(self, args: dict):
        self.min_batch_size: int = int(args.get("min_batch_size", 10))
        self.max_batch_size: int = int(args.get("max_batch_size", 100))
        self.delay: int = int(args.get("delay", 100))
        self.txn_pooling: bool = bool(args.get("txn_pooling", False))
        self.payload_size: int = int(args.get("payload_size", 50000))  # chars

        # Phase 2 knobs
        self.dispatch_batch_size: int = int(args.get("dispatch_batch_size", 100))

        # Optional
        self.counter: int = 0



    def _random_batch_size(self) -> int:
        if self.max_batch_size <= self.min_batch_size:
            return self.min_batch_size
        return random.randint(self.min_batch_size, self.max_batch_size)



    def _exec(self, cur, sql, params=None):
        """
        Wrapper around cursor.execute() that always disables server-side
        prepared statements (prepare=False), required for PgBouncer txn pooling.
        """
        if params is None:
            if self.txn_pooling:
                return cur.execute(sql, prepare=False)
            return cur.execute(sql)
        else:
            if self.txn_pooling:
                return cur.execute(sql, params, prepare=False)
            return cur.execute(sql, params)



    def _is_retryable_error(self, err: Exception) -> bool:
        return isinstance(err, SerializationFailure)



    def _run_txn_with_retries(self, conn: psycopg.Connection, fn, max_retries: int = 5):
        attempt = 0
        while True:
            try:
                try:
                    conn.rollback()
                except Exception:
                    pass
                conn.autocommit = True
                return fn(conn)
            except Exception as e:
                if not self._is_retryable_error(e) or attempt >= max_retries:
                    raise
                try:
                    conn.rollback()
                except Exception:
                    pass
                sleep_s = (2 ** attempt) * 0.05
                print(f"[retry] {fn.__name__} attempt {attempt+1} failed with {e}, retrying in {sleep_s:.3f}s")
                time.sleep(sleep_s)
                attempt += 1



    def setup(self, conn: psycopg.Connection, id: int, total_thread_count: int):
        self.id = id

        if self.txn_pooling:
            try:
                conn.prepare_threshold = 0
            except Exception as e:
                print(f"Could not disable prepared statements: {e}")

        with conn.cursor() as cur:
            print(f"My thread ID is {id}. The total count of threads is {total_thread_count}")
            print(self._exec(cur, "select version()").fetchone()[0])



    def loop(self):
        time.sleep(random.uniform(0.75, 1.25) * self.delay / 1000)
        return [self.insert, self.dispatch_publish]



    # Keep inserts as one-row-per-txn to maintain churn pressure
    def insert(self, conn: psycopg.Connection):
        batch_size = self._random_batch_size()
        for _ in range(batch_size):
            self._run_txn_with_retries(conn, self._insert_once)

    def _insert_once(self, conn: psycopg.Connection):
        original_autocommit = conn.autocommit

        insert_sql = """
            INSERT INTO outbox
              (aggregatetype, aggregateid, type, payload)
            VALUES
              ('svc', 'agg', 'event', repeat('x', %s))
            RETURNING id;
        """

        try:
            conn.autocommit = False
            with conn.cursor() as cur:
                self._exec(cur, insert_sql, (self.payload_size,))
                _ = cur.fetchone()
                if not _:
                    raise Exception("Failed to insert payload")
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.autocommit = original_autocommit



    def dispatch_publish(self, conn: psycopg.Connection):
        # One dispatcher txn per loop; retries handle 40001s cleanly.
        self._run_txn_with_retries(conn, self._dispatch_publish_once)

    def _dispatch_publish_once(self, conn: psycopg.Connection):
        original_autocommit = conn.autocommit

        # NOTE:
        # - Ordering by "timestamp" makes progress deterministic.
        # - SKIP LOCKED prevents blocking if another worker already claimed rows.
        # - Returning (id, publish_timestamp) gives the app a definitive list of published messages.
        dispatch_sql = """
            WITH cte AS (
              SELECT id
              FROM outbox
              WHERE is_published = false
              ORDER BY "timestamp"
              LIMIT %s
              FOR UPDATE SKIP LOCKED
            )
            UPDATE outbox o
            SET is_published = true,
                publish_timestamp = now()
            FROM cte
            WHERE o.id = cte.id
            RETURNING o.id, o.publish_timestamp;
        """

        try:
            conn.autocommit = False
            published = []

            with conn.cursor() as cur:
                self._exec(cur, dispatch_sql, (self.dispatch_batch_size,))
                # fetchall is safe here; max rows == dispatch_batch_size
                rows = cur.fetchall()
                for r in rows:
                    published.append((r[0], r[1]))

            conn.commit()

            # Optional: emit a lightweight progress line (useful in aggregated logs)
            if published:
                print(f"[dispatcher] published {len(published)} rows (example id={published[0][0]})")
            else:
                print("[dispatcher] published 0 rows (no work available)")

            return published

        except Exception:
            conn.rollback()
            raise
        finally:
            conn.autocommit = original_autocommit
