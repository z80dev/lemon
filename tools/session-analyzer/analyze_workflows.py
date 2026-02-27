"""Phase 2c: Multi-step workflow pattern detection."""

from __future__ import annotations

from collections import Counter, defaultdict
from pathlib import Path

import polars as pl


def _normalize_sequence(seq: tuple[str, ...]) -> tuple[str, ...]:
    """Normalize a tool sequence by collapsing consecutive duplicates."""
    if not seq:
        return seq
    result = [seq[0]]
    for item in seq[1:]:
        if item != result[-1]:
            result.append(item)
    return tuple(result)


def _sequences_similar(a: tuple[str, ...], b: tuple[str, ...]) -> bool:
    """Check if two sequences are similar (one is a normalized version of the other)."""
    return _normalize_sequence(a) == _normalize_sequence(b)


def run_workflow_analysis(output_dir: Path) -> pl.DataFrame:
    """Mine workflow patterns from session tool sequences. Returns ranked patterns."""
    sessions_path = output_dir / "sessions.parquet"
    if not sessions_path.exists():
        raise FileNotFoundError(f"Run extraction first: {sessions_path}")

    df = pl.read_parquet(sessions_path)
    if len(df) == 0:
        empty = pl.DataFrame(schema={
            "pattern": pl.Utf8,
            "normalized": pl.Utf8,
            "occurrences": pl.UInt32,
            "distinct_sessions": pl.UInt32,
            "sources": pl.List(pl.Utf8),
            "example_first_prompts": pl.List(pl.Utf8),
            "avg_length": pl.Float64,
        })
        empty.write_parquet(output_dir / "workflows.parquet")
        return empty

    # Extract subsequences from tool_sequence column
    subseq_counter: Counter = Counter()
    subseq_sessions: defaultdict[tuple, set] = defaultdict(set)
    subseq_sources: defaultdict[tuple, set] = defaultdict(set)
    subseq_prompts: defaultdict[tuple, list] = defaultdict(list)

    for row in df.iter_rows(named=True):
        tool_seq = row["tool_sequence"]
        if not tool_seq:
            continue
        tools = tool_seq.split("|")
        if len(tools) < 3:
            continue

        session_id = row["session_id"]
        source = row["source"]
        first_prompt = row["first_prompt"] or ""

        # Sliding windows of size 3-8
        for window_size in range(3, min(9, len(tools) + 1)):
            for i in range(len(tools) - window_size + 1):
                subseq = tuple(tools[i : i + window_size])
                subseq_counter[subseq] += 1
                subseq_sessions[subseq].add(session_id)
                subseq_sources[subseq].add(source)
                if len(subseq_prompts[subseq]) < 5:
                    if first_prompt and first_prompt not in subseq_prompts[subseq]:
                        subseq_prompts[subseq].append(first_prompt[:200])

    # Filter: 5+ occurrences across 3+ distinct sessions
    frequent = {
        seq: count
        for seq, count in subseq_counter.items()
        if count >= 5 and len(subseq_sessions[seq]) >= 3
    }

    if not frequent:
        # Relax criteria: 3+ occurrences across 2+ sessions
        frequent = {
            seq: count
            for seq, count in subseq_counter.items()
            if count >= 3 and len(subseq_sessions[seq]) >= 2
        }

    if not frequent:
        # Just take top patterns
        frequent = dict(subseq_counter.most_common(50))

    # Group similar workflows
    grouped: dict[tuple, list[tuple]] = {}
    for seq in sorted(frequent, key=lambda s: frequent[s], reverse=True):
        norm = _normalize_sequence(seq)
        found_group = False
        for group_key in grouped:
            if _normalize_sequence(group_key) == norm:
                grouped[group_key].append(seq)
                found_group = True
                break
        if not found_group:
            grouped[seq] = [seq]

    # Build results
    patterns_data = []
    for group_key, members in grouped.items():
        total_count = sum(frequent.get(m, 0) for m in members)
        all_sessions = set()
        all_sources = set()
        all_prompts = []
        for m in members:
            all_sessions |= subseq_sessions.get(m, set())
            all_sources |= subseq_sources.get(m, set())
            for p in subseq_prompts.get(m, []):
                if p not in all_prompts:
                    all_prompts.append(p)

        norm = _normalize_sequence(group_key)
        patterns_data.append({
            "pattern": " → ".join(group_key),
            "normalized": " → ".join(norm),
            "occurrences": total_count,
            "distinct_sessions": len(all_sessions),
            "sources": sorted(all_sources),
            "example_first_prompts": all_prompts[:5],
            "avg_length": sum(len(m) for m in members) / len(members),
        })

    patterns_data.sort(key=lambda x: x["occurrences"], reverse=True)
    # Keep top 100
    patterns_data = patterns_data[:100]

    workflows_df = pl.DataFrame(patterns_data, schema={
        "pattern": pl.Utf8,
        "normalized": pl.Utf8,
        "occurrences": pl.UInt32,
        "distinct_sessions": pl.UInt32,
        "sources": pl.List(pl.Utf8),
        "example_first_prompts": pl.List(pl.Utf8),
        "avg_length": pl.Float64,
    })
    workflows_df.write_parquet(output_dir / "workflows.parquet")
    return workflows_df
