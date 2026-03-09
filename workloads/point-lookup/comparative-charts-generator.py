#!/usr/bin/env python3
from __future__ import annotations

import argparse
import numpy as np
import os
import re
import subprocess
from pathlib import Path
from typing import Dict, List, Optional

import pandas as pd
import matplotlib.pyplot as plt


# ----------------------------
# Configuration
# ----------------------------

DEFAULT_SQL_TEMPLATE = "comparative-metrics-query.sql"
OUTPUT_ROOT = "output"

# Placeholders expected in the SQL template file:
PH_TEST_NAME = "__TEST_NAME__"
PH_BASELINE_PHASE = "__BASELINE_PHASE__"
PH_BASELINE_CONN = "__BASELINE_CONN_TYPE__"

# Column mapping / fallbacks for charting
COLUMN_ALIASES: Dict[str, List[str]] = {
    "phase": ["phase"],
    "connection_type": ["connection_type", "conn_type"],

    # Latency metric
    "svc_tail_3sigma_ms": ["svc_tail_3sigma_ms", "svc_tail_ms", "svc_p99_est_ms"],

    # Contention (optional)
    "contention_time_total_ms": [
        "contention_time_total_ms",
        "contention_total_ms",
        "stmt_contention_total_ms",
        "contention_ms_total",
    ],

    # IO proxy (optional)
    "bytes_read_total": [
        "bytes_read_total",
        "bytes_read_total_bytes",
        "stmt_bytes_read_total",
        "bytes_read_bytes_total",
    ],

    # Throughput inputs
    "stmt_exec_count": ["stmt_exec_count", "statement_exec_count", "total_stmt_exec_count"],
    "duration_s": ["duration_s", "test_duration_s", "run_duration_s"],

    # Network proxy (optional)
    "network_bytes_total": ["network_bytes_total", "network_bytes", "stmt_network_bytes_total"],
}


def pick_col(df: pd.DataFrame, logical_name: str) -> Optional[str]:
    for c in COLUMN_ALIASES.get(logical_name, []):
        if c in df.columns:
            return c
    return None


def ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def safe_num(s: pd.Series) -> pd.Series:
    return pd.to_numeric(s, errors="coerce").fillna(0.0)


def sql_quote_literal(val: str) -> str:
    # Safe-ish SQL string literal escaping for injection into query template.
    return "'" + val.replace("'", "''") + "'"


def render_sql_template(template_text: str, test_name: str, baseline_phase: str, baseline_conn: str) -> str:
    # Replace placeholders with SQL string literals
    rendered = template_text
    rendered = rendered.replace(PH_TEST_NAME, sql_quote_literal(test_name))
    rendered = rendered.replace(PH_BASELINE_PHASE, sql_quote_literal(baseline_phase))
    rendered = rendered.replace(PH_BASELINE_CONN, sql_quote_literal(baseline_conn))
    return rendered


def run_cockroach_sql_to_csv(url: str, certs_dir: str, sql_path: Path, out_csv: Path) -> None:
    cmd = [
        "cockroach", "sql",
        "--certs-dir", certs_dir,
        "--format=csv",
        "--url", url,
        "-f", str(sql_path),
    ]
    # Write stdout directly to CSV
    with out_csv.open("w", encoding="utf-8") as f:
        subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, text=True, check=True)


def format_improvement(current: float, baseline: float, higher_is_better: bool) -> float:
    if baseline == 0:
        return 0.0
    if higher_is_better:
        return (current - baseline) / baseline * 100.0
    return (baseline - current) / baseline * 100.0


def bar_chart(phases: List[str], values: List[float], title: str, ylabel: str, out_path: Path,
              annotate_pct: Optional[List[float]] = None) -> None:
    plt.figure()
    plt.bar(phases, values)
    plt.title(title)
    plt.ylabel(ylabel)
    plt.xticks(rotation=25, ha="right")

    if annotate_pct is not None:
        for i, (v, pct) in enumerate(zip(values, annotate_pct)):
            plt.text(i, v, f"{pct:+.1f}%", ha="center", va="bottom")

    plt.tight_layout()
    plt.savefig(out_path, dpi=180)
    plt.close()


def grouped_bar_chart(
    df: pd.DataFrame,
    phase_order: List[str],
    metric_col: str,
    title: str,
    ylabel: str,
    out_path: Path,
    baseline_phase: str,
    baseline_conn: str,
    higher_is_better: bool,
    scale_fn=None,  # optional: callable(series)->(scaled_series, ylabel_override)
) -> None:
    # Ensure required cols
    if "phase" not in df.columns:
        raise SystemExit("CSV missing required column: phase")
    if "connection_type" not in df.columns:
        # Fall back to single series plot
        phases = [p for p in phase_order if p in df["phase"].astype(str).unique().tolist()]
        vals = []
        for p in phases:
            sub = df[df["phase"].astype(str) == p]
            vals.append(float(safe_num(sub[metric_col]).iloc[0]) if len(sub) else 0.0)

        ser = pd.Series(vals, index=phases)
        if scale_fn:
            ser, ylabel2 = scale_fn(ser)
            ylabel = ylabel2

        # baseline: first matching phase row if present
        base_val = float(ser.loc[baseline_phase]) if baseline_phase in ser.index else float(ser.iloc[0])
        pct = [format_improvement(v, base_val, higher_is_better) for v in ser.tolist()]
        bar_chart(phases, ser.tolist(), title, ylabel, out_path, annotate_pct=pct)
        return

    # Pivot to phase x connection_type
    df2 = df.copy()
    df2["phase"] = df2["phase"].astype(str)
    df2["connection_type"] = df2["connection_type"].astype(str)

    pivot = df2.pivot_table(
        index="phase",
        columns="connection_type",
        values=metric_col,
        aggfunc="sum",
        fill_value=0.0,
    )

    phases = [p for p in phase_order if p in pivot.index]
    if not phases:
        phases = pivot.index.tolist()

    conn_types = list(pivot.columns)
    # Prefer stable ordering if present
    preferred = ["direct", "pooling"]
    conn_types = sorted(conn_types, key=lambda c: (preferred.index(c) if c in preferred else 999, c))

    # Reindex into desired order
    pivot = pivot.reindex(index=phases, columns=conn_types).fillna(0.0)

    # Optional scaling (e.g., bytes -> MB)
    if scale_fn:
        # Apply scaling per entire matrix so units are consistent across conn types
        stacked = pivot.stack()
        scaled, ylabel2 = scale_fn(stacked)
        ylabel = ylabel2
        pivot = scaled.unstack().reindex(index=phases, columns=conn_types).fillna(0.0)

    # Baseline value is the (baseline_phase, baseline_conn) cell if present
    if baseline_phase in pivot.index and baseline_conn in pivot.columns:
        baseline_val = float(pivot.loc[baseline_phase, baseline_conn])
    else:
        # Fallback to first cell
        baseline_val = float(pivot.iloc[0, 0])

    # Plot
    x = np.arange(len(phases))
    n = max(len(conn_types), 1)
    width = 0.8 / n

    plt.figure()
    for i, ct in enumerate(conn_types):
        vals = safe_num(pivot[ct]).tolist()
        offset = (i - (n - 1) / 2) * width
        bars = plt.bar(x + offset, vals, width=width, label=ct)

        # annotate percent vs baseline for each bar
        for j, v in enumerate(vals):
            pct = format_improvement(float(v), baseline_val, higher_is_better=higher_is_better)
            plt.text(x[j] + offset, float(v), f"{pct:+.1f}%", ha="center", va="bottom")

    plt.title(title)
    plt.ylabel(ylabel)
    plt.xticks(x, phases, rotation=25, ha="right")
    plt.legend(title="Connection")
    plt.tight_layout()
    plt.savefig(out_path, dpi=180)
    plt.close()


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Run comparative metrics query and generate README charts."
    )
    ap.add_argument("test_name", help="Test name used to select runs (and output folder name). Example: march_08")
    ap.add_argument("baseline_phase", help="Baseline phase name. Example: hotspot")
    ap.add_argument("baseline_connection_type", help="Baseline connection type. Example: direct or pooling")

    ap.add_argument("--url", default=os.environ.get("DB_URL", ""), help="CockroachDB connection URL (or env DB_URL)")
    ap.add_argument("--certs-dir", default=os.environ.get("DB_CERTS_DIR", ""), help="CockroachDB certificates directory (or env DB_CERTS_DIR)")
    ap.add_argument("--sql", default=DEFAULT_SQL_TEMPLATE, help="Path to comparative SQL template file")
    ap.add_argument("--phase-order", default="hotspot,scan_shape,concurrency,storage,region",
                    help="Comma-separated phase order for plots")
    ap.add_argument("--out-root", default=OUTPUT_ROOT, help="Output root directory")

    args = ap.parse_args()

    if not args.url:
        raise SystemExit("Missing DB URL. Provide --url or set DB_URL env var.")

    if not args.certs_dir:
        raise SystemExit("Missing DB certificates directory. Provide --certs-dir or set DB_CERTS_DIR env var.")

    sql_template_path = Path(args.sql)
    if not sql_template_path.exists():
        raise SystemExit(f"SQL template not found: {sql_template_path}")

    out_dir = Path(args.out_root) / args.test_name
    images_dir = out_dir / "images"
    ensure_dir(out_dir)
    ensure_dir(images_dir)

    # Render SQL template into a temp file in output dir (keeps run artifacts together)
    template_text = sql_template_path.read_text(encoding="utf-8")
    rendered_sql = render_sql_template(
        template_text,
        test_name=args.test_name,
        baseline_phase=args.baseline_phase,
        baseline_conn=args.baseline_connection_type,
    )
    rendered_sql_path = out_dir / "comparative-metrics-query.rendered.sql"
    rendered_sql_path.write_text(rendered_sql, encoding="utf-8")

    # Run query -> CSV
    out_csv = out_dir / "comparative_results.csv"
    try:
        run_cockroach_sql_to_csv(args.url, args.certs_dir, rendered_sql_path, out_csv)
    except subprocess.CalledProcessError as e:
        err = e.stderr or ""
        raise SystemExit(f"cockroach sql failed.\n\nSTDERR:\n{err}")

    # Load results
    df = pd.read_csv(out_csv)

    phase_col = pick_col(df, "phase")
    if not phase_col:
        raise SystemExit("CSV missing required column: phase")

    # Normalize column names expected by grouped_bar_chart
    if phase_col != "phase":
        df = df.rename(columns={phase_col: "phase"})
    if "connection_type" not in df.columns:
        # keep as-is; grouped_bar_chart will fall back
        pass

    # Order phases
    phase_order = [p.strip() for p in args.phase_order.split(",") if p.strip()]
    df[phase_col] = df[phase_col].astype(str)
    df["_phase_rank"] = df[phase_col].apply(lambda p: phase_order.index(p) if p in phase_order else 10_000)
    df = df.sort_values(["_phase_rank", phase_col]).drop(columns=["_phase_rank"])

    phases = df[phase_col].tolist()

    # Helper to find baseline row index
    baseline_mask = (df[phase_col] == args.baseline_phase)
    if "connection_type" in df.columns:
        baseline_mask = baseline_mask & (df["connection_type"].astype(str) == args.baseline_connection_type)

    if baseline_mask.any():
        baseline_idx = int(df[baseline_mask].index[0])
    else:
        # fallback: first row
        baseline_idx = int(df.index[0])

    # Chart 1: Tail latency (required)
    tail_col = pick_col(df, "svc_tail_3sigma_ms")
    if not tail_col:
        raise SystemExit("CSV missing required tail latency column (svc_tail_3sigma_ms or alias).")

    grouped_bar_chart(
        df=df,
        phase_order=phase_order,
        metric_col=tail_col,
        title="Tail Latency by Phase (svc mean + 3σ estimate)",
        ylabel="Latency (ms)",
        out_path=images_dir / "tail_latency.png",
        baseline_phase=args.baseline_phase,
        baseline_conn=args.baseline_connection_type,
        higher_is_better=False,
    )

    # Chart 2: Contention (optional)
    cont_col = pick_col(df, "contention_time_total_ms")
    if cont_col:
        grouped_bar_chart(
            df=df,
            phase_order=phase_order,
            metric_col=cont_col,
            title="Total Contention Wait Time by Phase",
            ylabel="Contention wait (ms)",
            out_path=images_dir / "contention_total.png",
            baseline_phase=args.baseline_phase,
            baseline_conn=args.baseline_connection_type,
            higher_is_better=False,
        )

    # Chart 3: Bytes read (optional)
    bytes_col = pick_col(df, "bytes_read_total")
    if bytes_col:
        def bytes_scale(series: pd.Series):
            m = float(series.max()) if len(series) else 0.0
            if m >= 1e9:
                return (series / 1e9, "Bytes read (GB)")
            if m >= 1e6:
                return (series / 1e6, "Bytes read (MB)")
            return (series, "Bytes read (bytes)")

        grouped_bar_chart(
            df=df,
            phase_order=phase_order,
            metric_col=bytes_col,
            title="Total Bytes Read by Phase (IO proxy)",
            ylabel="Bytes read",
            out_path=images_dir / "bytes_read_total.png",
            baseline_phase=args.baseline_phase,
            baseline_conn=args.baseline_connection_type,
            higher_is_better=False,
            scale_fn=bytes_scale,
        )

    # Chart 4: Throughput (exec/sec) (recommended)
    exec_col = pick_col(df, "stmt_exec_count")
    dur_col = pick_col(df, "duration_s")
    if exec_col:
        # Create a derived column for throughput so we can chart it like any other metric
        if dur_col and dur_col in df.columns:
            df["_stmt_throughput_s"] = safe_num(df[exec_col]) / safe_num(df[dur_col]).replace(0.0, 1.0)
            tput_col = "_stmt_throughput_s"
            title = "Statement Throughput by Phase"
            ylabel = "Statements / sec"
        else:
            tput_col = exec_col
            title = "Total Statement Executions by Phase"
            ylabel = "Total statement executions"

        grouped_bar_chart(
            df=df,
            phase_order=phase_order,
            metric_col=tput_col,
            title=title,
            ylabel=ylabel,
            out_path=images_dir / "throughput.png",
            baseline_phase=args.baseline_phase,
            baseline_conn=args.baseline_connection_type,
            higher_is_better=True,
        )

    # Chart 5: Network bytes (optional)
    net_col = pick_col(df, "network_bytes_total")
    if net_col:
        def net_scale(series: pd.Series):
            m = float(series.max()) if len(series) else 0.0
            if m >= 1e9:
                return (series / 1e9, "Network bytes (GB)")
            if m >= 1e6:
                return (series / 1e6, "Network bytes (MB)")
            return (series, "Network bytes")

        grouped_bar_chart(
            df=df,
            phase_order=phase_order,
            metric_col=net_col,
            title="Total Network Bytes by Phase (sampled proxy)",
            ylabel="Network bytes",
            out_path=images_dir / "network_bytes_total.png",
            baseline_phase=args.baseline_phase,
            baseline_conn=args.baseline_connection_type,
            higher_is_better=False,
            scale_fn=net_scale,
        )

    print(f"✅ Wrote CSV: {out_csv}")
    print(f"✅ Wrote charts to: {images_dir}")
    print("Generated (as available): tail_latency.png, contention_total.png, bytes_read_total.png, throughput.png, network_bytes_total.png")


if __name__ == "__main__":
    main()
