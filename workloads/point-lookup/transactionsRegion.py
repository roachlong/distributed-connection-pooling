import psycopg
from psycopg.errors import SerializationFailure
import random
import time
import gzip


class Transactionsregion:
    """
    Phase 4: Multi-region locality (REGIONAL BY ROW) + region-scoped dispatcher.

    Tables:
      - outbox: hot queue metadata (REGIONAL BY ROW on region, supports SKIP LOCKED)
      - outbox_payload: cold BYTES payload, also REGIONAL BY ROW

    Workload:
      - Insert (1 txn): insert outbox row -> insert compressed payload row
      - Dispatcher publish (1 txn): claim unpublished rows in *this gateway's region*
        using FOR UPDATE SKIP LOCKED, update publish_timestamp, return (id, publish_timestamp)

    This keeps leaseholder operations local and reduces cross-region RPCs.
    """

    GZIP_MAGIC = b"GZ1:"

    def __init__(self, args: dict):
        self.min_batch_size: int = int(args.get("min_batch_size", 10))
        self.max_batch_size: int = int(args.get("max_batch_size", 100))
        self.delay: int = int(args.get("delay", 100))
        self.txn_pooling: bool = bool(args.get("txn_pooling", False))

        self.payload_size: int = int(args.get("payload_size", 50000))
        self.enable_compression: bool = bool(args.get("enable_compression", True))
        self.dispatch_batch_size: int = int(args.get("dispatch_batch_size", 100))

        self.verify_decompression_rate: float = float(args.get("verify_decompression_rate", 0.0))



    def _random_batch_size(self) -> int:
        if self.max_batch_size <= self.min_batch_size:
            return self.min_batch_size
        return random.randint(self.min_batch_size, self.max_batch_size)



    def _exec(self, cur, sql, params=None):
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
                time.sleep((2 ** attempt) * 0.05)
                attempt += 1



    def _encode_payload(self, raw: bytes) -> bytes:
        if not self.enable_compression:
            return raw
        return self.GZIP_MAGIC + gzip.compress(raw)

    def _decode_payload(self, stored: bytes) -> bytes:
        if stored is None:
            return b""
        if stored.startswith(self.GZIP_MAGIC):
            return gzip.decompress(stored[len(self.GZIP_MAGIC):])
        return stored



    def setup(self, conn: psycopg.Connection, id: int, total_thread_count: int):
        self.id = id
        if self.txn_pooling:
            try:
                conn.prepare_threshold = 0
            except Exception:
                pass
        with conn.cursor() as cur:
            print(f"My thread ID is {id}. Total threads: {total_thread_count}")
            print(self._exec(cur, "select version()").fetchone()[0])



    def loop(self):
        time.sleep(random.uniform(0.75, 1.25) * self.delay / 1000)
        return [self.insert, self.dispatch_publish]



    def insert(self, conn: psycopg.Connection):
        batch_size = self._random_batch_size()
        for _ in range(batch_size):
            self._run_txn_with_retries(conn, self._insert_once)

    def _insert_once(self, conn: psycopg.Connection):
        original_autocommit = conn.autocommit

        insert_meta_sql = """
            INSERT INTO outbox
              (aggregatetype, aggregateid, type)
            VALUES
              (%s, %s, %s)
            RETURNING id;
        """

        insert_payload_sql = """
            INSERT INTO outbox_payload
              (id, payload)
            VALUES
              (%s, %s);
        """

        try:
            conn.autocommit = False

            raw = b"x" * self.payload_size
            payload = self._encode_payload(raw)

            with conn.cursor() as cur:
                self._exec(cur, insert_meta_sql, ("svc", "agg", "event"))
                row = cur.fetchone()
                if not row:
                    raise Exception("Failed to insert outbox meta row")
                msg_id = row[0]

                self._exec(cur, insert_payload_sql, (msg_id, payload))

                if self.verify_decompression_rate > 0 and random.random() < self.verify_decompression_rate:
                    self._exec(cur, "SELECT payload FROM outbox_payload WHERE id=%s;", (msg_id,))
                    stored = cur.fetchone()[0]
                    decoded = self._decode_payload(stored)
                    if len(decoded) != self.payload_size:
                        raise Exception(f"Decompression validation failed: got {len(decoded)} expected {self.payload_size}")

            conn.commit()

        except Exception:
            conn.rollback()
            raise
        finally:
            conn.autocommit = original_autocommit



    def dispatch_publish(self, conn: psycopg.Connection):
        self._run_txn_with_retries(conn, self._dispatch_publish_once)

    def _dispatch_publish_once(self, conn: psycopg.Connection):
        original_autocommit = conn.autocommit

        # Region-scoped dispatcher:
        # Each worker only processes rows homed in its gateway region.
        dispatch_sql = """
            WITH cte AS (
              SELECT id
              FROM outbox
              WHERE crdb_region = gateway_region()::crdb_internal_region
                AND is_published = false
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
            with conn.cursor() as cur:
                self._exec(cur, dispatch_sql, (self.dispatch_batch_size,))
                rows = cur.fetchall()
            conn.commit()

            if rows:
                print(f"[dispatcher] published {len(rows)} rows (example id={rows[0][0]})")
            else:
                print("[dispatcher] published 0 rows")

            return rows

        except Exception:
            conn.rollback()
            raise
        finally:
            conn.autocommit = original_autocommit
