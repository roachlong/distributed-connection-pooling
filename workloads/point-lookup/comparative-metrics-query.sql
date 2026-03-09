WITH
/* ============================================================================
   1) Define your test cycles (edit timestamps + connection_type).
   - phase: ALSO the database name
   - app_name: the dbworkload application_name
   - start_ts/end_ts: inclusive/exclusive window
   ============================================================================ */
phases AS (
  SELECT
    phase,
    app_name,
    connection_type,
    start_ts,
    end_ts
  FROM defaultdb.test_runs
  WHERE test_name = __TEST_NAME__
),

/* ============================================================================
   2) Pull per-fingerprint stats from crdb_internal.statement_statistics
      using ONLY documented JSON paths from your pasted docs.

      Time bucketing:
        statement_statistics.aggregated_ts is hourly UTC bucket start time.
        We include all hour buckets that overlap the run window:
          aggregated_ts >= date_trunc('hour', start_ts)
          aggregated_ts <  date_trunc('hour', end_ts) + 1h

      Filters:
        - app_name matches your dbworkload app name
        - metadata->>'db' matches the database (= phase)
   ============================================================================ */
stmt_fingerprint_stats AS (
  SELECT
    p.phase,
    p.connection_type,

    /* ---- core execution count (per fingerprint, per hour bucket) ---- */
    COALESCE((s.statistics->'statistics'->>'cnt')::FLOAT8, 0.0) AS cnt,

    /* ---- svcLat/runLat NumericStat (seconds) ---- */
    COALESCE((s.statistics->'statistics'->'svcLat'->>'mean')::FLOAT8, 0.0)   AS svc_mean_s,
    COALESCE((s.statistics->'statistics'->'svcLat'->>'sqDiff')::FLOAT8, 0.0) AS svc_sqdiff_s2,
    COALESCE((s.statistics->'statistics'->'runLat'->>'mean')::FLOAT8, 0.0)   AS run_mean_s,
    COALESCE((s.statistics->'statistics'->'runLat'->>'sqDiff')::FLOAT8, 0.0) AS run_sqdiff_s2,

    /* ---- bytesRead/rowsRead/rowsWritten NumericStat ---- */
    COALESCE((s.statistics->'statistics'->'bytesRead'->>'mean')::FLOAT8, 0.0)   AS bytes_read_mean,
    COALESCE((s.statistics->'statistics'->'bytesRead'->>'sqDiff')::FLOAT8, 0.0) AS bytes_read_sqdiff,

    COALESCE((s.statistics->'statistics'->'rowsRead'->>'mean')::FLOAT8, 0.0)    AS rows_read_mean,
    COALESCE((s.statistics->'statistics'->'rowsRead'->>'sqDiff')::FLOAT8, 0.0)  AS rows_read_sqdiff,

    COALESCE((s.statistics->'statistics'->'rowsWritten'->>'mean')::FLOAT8, 0.0)   AS rows_written_mean,
    COALESCE((s.statistics->'statistics'->'rowsWritten'->>'sqDiff')::FLOAT8, 0.0) AS rows_written_sqdiff,

    /* ---- reliability-ish counters (documented) ---- */
    COALESCE((s.statistics->'statistics'->>'failureCount')::FLOAT8, 0.0)    AS failure_count,
    COALESCE((s.statistics->'statistics'->>'maxRetries')::FLOAT8, 0.0)      AS max_retries,
    COALESCE((s.statistics->'statistics'->>'firstAttemptCnt')::FLOAT8, 0.0) AS first_attempt_cnt,

    /* ---- sampled execution_statistics (documented; may be sparse) ---- */
    COALESCE((s.statistics->'execution_statistics'->>'cnt')::FLOAT8, 0.0) AS exec_sample_cnt,

    /* contentionTime is in seconds */
    COALESCE((s.statistics->'execution_statistics'->'contentionTime'->>'mean')::FLOAT8, 0.0)   AS sampled_cont_mean_s,
    COALESCE((s.statistics->'execution_statistics'->'contentionTime'->>'sqDiff')::FLOAT8, 0.0) AS sampled_cont_sqdiff_s2,

    /* networkBytes/messages are counts/bytes (sampled) */
    COALESCE((s.statistics->'execution_statistics'->'networkBytes'->>'mean')::FLOAT8, 0.0)   AS sampled_net_bytes_mean,
    COALESCE((s.statistics->'execution_statistics'->'networkMsgs'->>'mean')::FLOAT8, 0.0)    AS sampled_net_msgs_mean

  FROM phases p
  JOIN crdb_internal.statement_statistics s
    ON s.app_name = p.app_name
   AND s.metadata->>'db' = p.phase
   AND s.aggregated_ts >= date_trunc('hour', p.start_ts)
   AND s.aggregated_ts <  date_trunc('hour', p.end_ts) + interval '1 hour'
),

/* ============================================================================
   3) Aggregate pass #1: get totals and global means.
   ============================================================================ */
stmt_pass1 AS (
  SELECT
    phase,
    connection_type,

    /* total executions across all fingerprints */
    SUM(cnt) AS N,

    /* weighted sums for global mean */
    SUM(cnt * svc_mean_s) AS svc_sum,
    SUM(cnt * run_mean_s) AS run_sum,
    SUM(cnt * bytes_read_mean) AS bytes_read_sum,
    SUM(cnt * rows_read_mean) AS rows_read_sum,
    SUM(cnt * rows_written_mean) AS rows_written_sum,

    /* sum of per-fingerprint M2 components */
    SUM(svc_sqdiff_s2) AS svc_m2_sum,
    SUM(run_sqdiff_s2) AS run_m2_sum,

    /* counters */
    SUM(failure_count) AS failure_count_total,
    MAX(max_retries) AS max_retries_observed,
    SUM(first_attempt_cnt) AS first_attempt_cnt_total,

    /* sampled execution_statistics: report sampled means (weighted by sample cnt) */
    SUM(exec_sample_cnt) AS exec_sample_N,
    SUM(exec_sample_cnt * sampled_cont_mean_s) AS sampled_cont_sum,
    SUM(sampled_cont_sqdiff_s2) AS sampled_cont_m2_sum,
    SUM(exec_sample_cnt * sampled_net_bytes_mean) AS sampled_net_bytes_sum,
    SUM(exec_sample_cnt * sampled_net_msgs_mean)  AS sampled_net_msgs_sum

  FROM stmt_fingerprint_stats
  GROUP BY phase, connection_type
),
stmt_means AS (
  SELECT
    phase,
    connection_type,

    N,

    CASE WHEN N > 0 THEN svc_sum / N ELSE 0.0 END AS svc_global_mean_s,
    CASE WHEN N > 0 THEN run_sum / N ELSE 0.0 END AS run_global_mean_s,

    CASE WHEN N > 0 THEN bytes_read_sum / N ELSE 0.0 END AS bytes_read_global_mean,
    CASE WHEN N > 0 THEN rows_read_sum / N ELSE 0.0 END AS rows_read_global_mean,
    CASE WHEN N > 0 THEN rows_written_sum / N ELSE 0.0 END AS rows_written_global_mean,

    svc_m2_sum,
    run_m2_sum,

    failure_count_total,
    max_retries_observed,
    first_attempt_cnt_total,

    exec_sample_N,
    CASE WHEN exec_sample_N > 0 THEN sampled_cont_sum / exec_sample_N ELSE 0.0 END AS sampled_cont_global_mean_s,
    sampled_cont_m2_sum,
    CASE WHEN exec_sample_N > 0 THEN sampled_net_bytes_sum / exec_sample_N ELSE 0.0 END AS sampled_net_bytes_mean,
    CASE WHEN exec_sample_N > 0 THEN sampled_net_msgs_sum  / exec_sample_N ELSE 0.0 END AS sampled_net_msgs_mean

  FROM stmt_pass1
),

/* ============================================================================
   4) Aggregate pass #2: combine M2 properly:
      global_M2 = Σ( M2_i + n_i * (mean_i - global_mean)^2 )
      We already have Σ(M2_i) from pass1, so we just need the correction term.
   ============================================================================ */
stmt_correction AS (
  SELECT
    f.phase,
    f.connection_type,

    SUM(f.cnt * pow(f.svc_mean_s - m.svc_global_mean_s, 2)) AS svc_corr,
    SUM(f.cnt * pow(f.run_mean_s - m.run_global_mean_s, 2)) AS run_corr

  FROM stmt_fingerprint_stats f
  JOIN stmt_means m
    ON m.phase = f.phase
   AND m.connection_type = f.connection_type
  GROUP BY f.phase, f.connection_type
),

/* ============================================================================
   5) Final statement performance metrics (ms) + tail estimate (mean + 3*stddev).
   ============================================================================ */
stmt_perf AS (
  SELECT
    m.phase,
    m.connection_type,

    /* totals */
    m.N AS stmt_exec_count,

    /* means (ms) */
    (m.svc_global_mean_s * 1000.0) AS svc_mean_ms,
    (m.run_global_mean_s * 1000.0) AS run_mean_ms,

    /* stddev (ms) using sample variance */
    CASE WHEN m.N > 1
      THEN sqrt( (m.svc_m2_sum + c.svc_corr) / (m.N - 1) ) * 1000.0
      ELSE 0.0
    END AS svc_stddev_ms,

    CASE WHEN m.N > 1
      THEN sqrt( (m.run_m2_sum + c.run_corr) / (m.N - 1) ) * 1000.0
      ELSE 0.0
    END AS run_stddev_ms,

    /* tail proxy */
    CASE WHEN m.N > 1
      THEN (m.svc_global_mean_s * 1000.0)
           + 3.0 * sqrt( (m.svc_m2_sum + c.svc_corr) / (m.N - 1) ) * 1000.0
      ELSE (m.svc_global_mean_s * 1000.0)
    END AS svc_tail_3sigma_ms,

    CASE WHEN m.N > 1
      THEN (m.run_global_mean_s * 1000.0)
           + 3.0 * sqrt( (m.run_m2_sum + c.run_corr) / (m.N - 1) ) * 1000.0
      ELSE (m.run_global_mean_s * 1000.0)
    END AS run_tail_3sigma_ms,

    /* totals (approx = Σ cnt * mean) */
    /* note: bytesRead is disk reads, not “payload size” */
    (SELECT SUM(cnt * bytes_read_mean) FROM stmt_fingerprint_stats f
      WHERE f.phase=m.phase AND f.connection_type=m.connection_type) AS bytes_read_total,

    (SELECT SUM(cnt * rows_read_mean) FROM stmt_fingerprint_stats f
      WHERE f.phase=m.phase AND f.connection_type=m.connection_type) AS rows_read_total,

    (SELECT SUM(cnt * rows_written_mean) FROM stmt_fingerprint_stats f
      WHERE f.phase=m.phase AND f.connection_type=m.connection_type) AS rows_written_total,

    /* counters */
    m.failure_count_total,
    m.max_retries_observed,
    m.first_attempt_cnt_total,

    /* sampled execution_statistics (reported as sampled means) */
    m.exec_sample_N AS exec_sample_count,
    (m.sampled_cont_global_mean_s * 1000.0) AS sampled_cont_mean_ms,
    m.sampled_net_bytes_mean AS sampled_network_bytes_mean,
    m.sampled_net_msgs_mean  AS sampled_network_msgs_mean

  FROM stmt_means m
  JOIN stmt_correction c
    ON c.phase = m.phase
   AND c.connection_type = m.connection_type
),

/* ============================================================================
   6) Contention events (real timestamps) across the window.
      NOTE: this table is documented as expensive fan-out; use sparingly.
      Filter by database_name = phase so each run only counts its DB.
   ============================================================================ */
contention AS (
  SELECT
    p.phase,
    p.connection_type,
    COALESCE(COUNT(e.*), 0) AS contention_events,
    COALESCE(SUM(EXTRACT(EPOCH FROM e.contention_duration) * 1000.0), 0.0) AS contention_total_wait_ms,
    COALESCE(MAX(EXTRACT(EPOCH FROM e.contention_duration) * 1000.0), 0.0) AS contention_max_wait_ms
  FROM phases p
  LEFT JOIN crdb_internal.transaction_contention_events e
    ON e.database_name = p.phase
   AND e.collection_ts >= p.start_ts
   AND e.collection_ts <  p.end_ts
  GROUP BY p.phase, p.connection_type
),

/* ============================================================================
   7) Combine into one row per phase.
   ============================================================================ */
combined AS (
  SELECT
    p.phase,
    p.app_name,
    p.connection_type,
    p.start_ts,
    p.end_ts,
    EXTRACT(EPOCH FROM (p.end_ts - p.start_ts))::INT AS duration_s,

    sp.stmt_exec_count,

    sp.svc_mean_ms,
    sp.svc_stddev_ms,
    sp.svc_tail_3sigma_ms,

    sp.run_mean_ms,
    sp.run_stddev_ms,
    sp.run_tail_3sigma_ms,

    sp.bytes_read_total,
    sp.rows_read_total,
    sp.rows_written_total,

    sp.failure_count_total,
    sp.max_retries_observed,
    sp.first_attempt_cnt_total,

    /* sampled execution stats (means only) */
    sp.exec_sample_count,
    sp.sampled_cont_mean_ms,
    sp.sampled_network_bytes_mean,
    sp.sampled_network_msgs_mean,

    c.contention_events,
    c.contention_total_wait_ms,
    c.contention_max_wait_ms

  FROM phases p
  LEFT JOIN stmt_perf  sp ON sp.phase = p.phase AND sp.connection_type = p.connection_type
  LEFT JOIN contention c  ON c.phase  = p.phase AND c.connection_type  = p.connection_type
),

/* ============================================================================
   8) Baseline row (hotspot).
   ============================================================================ */
baseline AS (
  SELECT *
  FROM combined
  WHERE phase = __BASELINE_PHASE__
    AND connection_type = __BASELINE_CONN_TYPE__
  LIMIT 1
)

SELECT
  c.phase,
  c.app_name,
  c.connection_type,
  c.start_ts,
  c.end_ts,
  c.duration_s,

  /* raw metrics */
  c.stmt_exec_count,

  c.svc_mean_ms,
  c.svc_stddev_ms,
  c.svc_tail_3sigma_ms,

  c.run_mean_ms,
  c.run_stddev_ms,
  c.run_tail_3sigma_ms,

  c.bytes_read_total,
  c.rows_read_total,
  c.rows_written_total,

  c.failure_count_total,
  c.max_retries_observed,
  c.first_attempt_cnt_total,

  c.exec_sample_count,
  c.sampled_cont_mean_ms,
  c.sampled_network_bytes_mean,
  c.sampled_network_msgs_mean,

  c.contention_events,
  c.contention_total_wait_ms,
  c.contention_max_wait_ms,

  /* % change vs baseline */

  /* throughput: higher is better */
  ROUND(100.0 * (c.stmt_exec_count - b.stmt_exec_count) / NULLIF(b.stmt_exec_count, 0), 2)
    AS pct_stmt_exec_count_vs_baseline,

  /* latency: lower is better */
  ROUND(100.0 * (b.svc_mean_ms - c.svc_mean_ms) / NULLIF(b.svc_mean_ms, 0), 2)
    AS pct_svc_mean_improvement_vs_baseline,

  ROUND(100.0 * (b.svc_tail_3sigma_ms - c.svc_tail_3sigma_ms) / NULLIF(b.svc_tail_3sigma_ms, 0), 2)
    AS pct_svc_tail_3sigma_improvement_vs_baseline,

  ROUND(100.0 * (b.run_mean_ms - c.run_mean_ms) / NULLIF(b.run_mean_ms, 0), 2)
    AS pct_run_mean_improvement_vs_baseline,

  ROUND(100.0 * (b.run_tail_3sigma_ms - c.run_tail_3sigma_ms) / NULLIF(b.run_tail_3sigma_ms, 0), 2)
    AS pct_run_tail_3sigma_improvement_vs_baseline,

  /* contention: lower is better */
  ROUND(100.0 * (b.contention_total_wait_ms - c.contention_total_wait_ms) / NULLIF(b.contention_total_wait_ms, 0), 2)
    AS pct_contention_wait_improvement_vs_baseline,

  ROUND(100.0 * (b.contention_max_wait_ms - c.contention_max_wait_ms) / NULLIF(b.contention_max_wait_ms, 0), 2)
    AS pct_contention_max_wait_improvement_vs_baseline,

  /* IO proxies: lower is better (bytesRead is disk reads) */
  ROUND(100.0 * (b.bytes_read_total - c.bytes_read_total) / NULLIF(b.bytes_read_total, 0), 2)
    AS pct_bytes_read_improvement_vs_baseline,

  ROUND(100.0 * (b.rows_written_total - c.rows_written_total) / NULLIF(b.rows_written_total, 0), 2)
    AS pct_rows_written_improvement_vs_baseline

FROM combined c
CROSS JOIN baseline b
ORDER BY
  CASE c.phase
    WHEN 'hotspot' THEN 0
    WHEN 'scan_shape' THEN 1
    WHEN 'concurrency' THEN 2
    WHEN 'storage' THEN 3
    WHEN 'region' THEN 4
    ELSE 99
  END,
  CASE c.connection_type
    WHEN 'direct' THEN 0
    WHEN 'pooling' THEN 1
    ELSE 99
  END;
