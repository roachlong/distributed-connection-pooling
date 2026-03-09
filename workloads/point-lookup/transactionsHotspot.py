import psycopg
from psycopg.errors import SerializationFailure, OperationalError
import random
import time

class Transactionshotspot:

    def __init__(self, args: dict):
        # args is a dict of string passed with the --args flag
        # user passed a yaml/json, in python that's a dict object
        self.min_batch_size: int = int(args.get("min_batch_size", 10))
        self.max_batch_size: int = int(args.get("max_batch_size", 100))
        self.delay: int = int(args.get("delay", 100))
        self.txn_pooling: bool = bool(args.get("txn_pooling", False))
        self.payload_size: int = int(args.get("payload_size", 50000))  # chars

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
        self.msg_ids = []
        return [self.insert, self.select, self.update]



    # conn is an instance of a psycopg connection object
    # setting autocommit=False to simulate explicit commit
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



    # conn is an instance of a psycopg connection object
    # setting autocommit=False to simulate explicit commit
    def select(self, conn: psycopg.Connection):
        for msg_id in self.msg_ids:
            self._run_txn_with_retries(conn, lambda c: self._select_once(c, msg_id))


    def _select_once(self, conn: psycopg.Connection, msg_id):
        original_autocommit = conn.autocommit

        # select the timestamp of the unpublished message
        select_sql = """
            SELECT crdb_internal_mvcc_timestamp
            FROM outbox@{NO_FULL_SCAN}
            WHERE id = %s AND is_published = false;
        """

        try:
            conn.autocommit = False

            with conn.cursor() as cur:
                self._exec(cur, select_sql, (msg_id,))
                cur.fetchone()

            conn.commit()

        except Exception as e:
            conn.rollback()
            raise

        finally:
            conn.autocommit = original_autocommit



    # conn is an instance of a psycopg connection object
    # setting autocommit=False to simulate explicit commit
    def update(self, conn: psycopg.Connection):
        for msg_id in self.msg_ids:
            self._run_txn_with_retries(conn, lambda c: self._update_once(c, msg_id))


    def _update_once(self, conn: psycopg.Connection, msg_id):
        original_autocommit = conn.autocommit

        # mark the message as published
        update_sql = """
            UPDATE outbox@{NO_FULL_SCAN}
            SET is_published = true,
                publish_timestamp = now()
            WHERE id = %s;
        """

        try:
            conn.autocommit = False

            with conn.cursor() as cur:
                self._exec(cur, update_sql, (msg_id,))

            conn.commit()

        except Exception as e:
            conn.rollback()
            raise

        finally:
            conn.autocommit = original_autocommit
