import psycopg
from psycopg.errors import SerializationFailure
import random
import time


class Transactionsscanshape:
    """
    Phase 1: Remove the scan-shaped read entirely by publishing with a guarded UPDATE...RETURNING.
    This eliminates the SELECT that (per statement bundle) was planned as:
      FULL SCAN of partial index -> filter id=$1 -> index join
    and that spent ~all time in KV lock contention.

    Flow per cycle:
      - Insert N messages (one txn each) capturing msg_ids
      - Publish each msg_id using UPDATE ... WHERE is_published=false RETURNING publish_timestamp
    """

    def __init__(self, args: dict):
        self.min_batch_size: int = int(args.get("min_batch_size", 10))
        self.max_batch_size: int = int(args.get("max_batch_size", 100))
        self.delay: int = int(args.get("delay", 100))
        self.txn_pooling: bool = bool(args.get("txn_pooling", False))
        self.payload_size: int = int(args.get("payload_size", 50000))  # chars

        # Optional knobs
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
        self.msg_ids = []
        # Phase 1: no SELECT step
        return [self.insert, self.publish]



    def insert(self, conn: psycopg.Connection):
        batch_size = self._random_batch_size()
        for _ in range(batch_size):
            self._run_txn_with_retries(conn, self._insert_once)

    def _insert_once(self, conn: psycopg.Connection):
        original_autocommit = conn.autocommit

        # Parameterize payload size so you can keep Phase 1 comparable to baseline
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
                row = cur.fetchone()
                if not row:
                    raise Exception("Failed to insert payload")
                self.msg_ids.append(row[0])
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.autocommit = original_autocommit



    def publish(self, conn: psycopg.Connection):
        # Publish each message individually, like baseline (still high concurrency),
        # but without a preceding SELECT that can scan/block.
        for msg_id in self.msg_ids:
            self._run_txn_with_retries(conn, lambda c: self._publish_once(c, msg_id))

    def _publish_once(self, conn: psycopg.Connection, msg_id):
        original_autocommit = conn.autocommit

        publish_sql = """
            UPDATE outbox
            SET is_published = true,
                publish_timestamp = now()
            WHERE id = %s
            AND is_published = false
            RETURNING publish_timestamp;
        """

        try:
            conn.autocommit = False
            with conn.cursor() as cur:
                self._exec(cur, publish_sql, (msg_id,))
                row = cur.fetchone()
                # If row is None, it means the row was already published (or missing).
                # In Phase 1 repro we treat it as a "lost race", not an error.
                # But you can optionally count it.
                _ = row[0] if row else None
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.autocommit = original_autocommit
