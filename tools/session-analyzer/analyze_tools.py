"""Phase 2b: Tool call sequence mining and frequency analysis."""

from __future__ import annotations

from collections import Counter
from pathlib import Path

import polars as pl


def _extract_ngrams(seq: list[str], n: int) -> list[tuple[str, ...]]:
    """Extract n-grams from a sequence."""
    if len(seq) < n:
        return []
    return [tuple(seq[i : i + n]) for i in range(len(seq) - n + 1)]


def run_tool_analysis(output_dir: Path) -> dict:
    """Analyze tool usage patterns. Returns dict of analysis results."""
    tools_path = output_dir / "tool_calls.parquet"
    if not tools_path.exists():
        raise FileNotFoundError(f"Run extraction first: {tools_path}")

    df = pl.read_parquet(tools_path)
    results: dict = {}

    if len(df) == 0:
        results["frequency"] = pl.DataFrame(schema={"tool_name": pl.Utf8, "count": pl.UInt32})
        results["frequency_by_source"] = pl.DataFrame(schema={"source": pl.Utf8, "tool_name": pl.Utf8, "count": pl.UInt32})
        results["ngrams"] = {}
        results["cooccurrence"] = pl.DataFrame()
        results["errors"] = pl.DataFrame()
        return results

    # ── 1. Frequency ────────────────────────────────────────────────

    freq = (
        df.group_by("tool_name")
        .agg(pl.len().alias("count"))
        .sort("count", descending=True)
    )
    results["frequency"] = freq

    freq_by_source = (
        df.group_by("source", "tool_name")
        .agg(pl.len().alias("count"))
        .sort("count", descending=True)
    )
    results["frequency_by_source"] = freq_by_source

    # ── 2. N-gram sequences ────────────────────────────────────────

    # Build tool sequences per (session, prompt_idx)
    turn_seqs = (
        df.sort("call_idx")
        .group_by("session_id", "prompt_idx")
        .agg(pl.col("tool_name").alias("tools"))
    )

    ngram_counters: dict[int, Counter] = {n: Counter() for n in (2, 3, 4)}

    for row in turn_seqs.iter_rows(named=True):
        tools = row["tools"]
        if not tools:
            continue
        for n in (2, 3, 4):
            for gram in _extract_ngrams(tools, n):
                ngram_counters[n][gram] += 1

    # Convert to sorted lists
    ngram_results = {}
    for n, counter in ngram_counters.items():
        top = counter.most_common(50)
        ngram_results[n] = [
            {"sequence": " → ".join(gram), "count": count}
            for gram, count in top
        ]

    results["ngrams"] = ngram_results

    # ── 3. Co-occurrence ────────────────────────────────────────────

    # Which tools appear together in the same turn
    cooccur_counter: Counter = Counter()
    for row in turn_seqs.iter_rows(named=True):
        tools = row["tools"]
        if not tools:
            continue
        unique = sorted(set(tools))
        for i, t1 in enumerate(unique):
            for t2 in unique[i + 1 :]:
                cooccur_counter[(t1, t2)] += 1

    cooccur_data = [
        {"tool_a": pair[0], "tool_b": pair[1], "count": count}
        for pair, count in cooccur_counter.most_common(50)
    ]
    results["cooccurrence"] = pl.DataFrame(cooccur_data) if cooccur_data else pl.DataFrame(
        schema={"tool_a": pl.Utf8, "tool_b": pl.Utf8, "count": pl.UInt32}
    )

    # ── 4. Error patterns ──────────────────────────────────────────

    error_df = df.filter(pl.col("is_error"))
    if len(error_df) > 0:
        error_freq = (
            error_df.group_by("tool_name")
            .agg(pl.len().alias("error_count"))
            .sort("error_count", descending=True)
        )
        # Join with total counts for error rate
        error_freq = error_freq.join(freq, on="tool_name", how="left").with_columns(
            (pl.col("error_count") / pl.col("count") * 100).alias("error_rate_pct")
        )
        results["errors"] = error_freq
    else:
        results["errors"] = pl.DataFrame(
            schema={"tool_name": pl.Utf8, "error_count": pl.UInt32, "count": pl.UInt32, "error_rate_pct": pl.Float64}
        )

    # ── Save artifacts ──────────────────────────────────────────────

    freq.write_parquet(output_dir / "tool_frequency.parquet")
    freq_by_source.write_parquet(output_dir / "tool_frequency_by_source.parquet")

    return results
