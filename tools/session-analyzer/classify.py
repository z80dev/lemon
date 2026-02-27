"""Phase 3: Classify findings → skill/subagent/tool candidates."""

from __future__ import annotations

from pathlib import Path

import polars as pl

# Tools that indicate exploration/research patterns
EXPLORATION_TOOLS = {"Read", "read", "Grep", "grep", "Glob", "glob", "find", "ls", "cat", "head"}
# Tools that indicate editing/mutation patterns
MUTATION_TOOLS = {"Edit", "edit", "Write", "write", "Bash", "bash", "exec_command", "shell"}


def _score_skill(
    cluster: dict,
    workflow_matches: list[dict],
    tool_freq: dict[str, int],
) -> dict:
    """Score a prompt cluster as a skill candidate."""
    score = 0.0
    reasons = []

    count = cluster.get("count", 0)
    if count >= 20:
        score += 3.0
        reasons.append(f"high frequency ({count} occurrences)")
    elif count >= 10:
        score += 2.0
        reasons.append(f"moderate frequency ({count})")
    elif count >= 5:
        score += 1.0

    # Multi-source bonus
    sources = cluster.get("sources", [])
    if len(sources) > 1:
        score += 1.0
        reasons.append(f"cross-source ({', '.join(sources)})")

    # Matching workflow patterns
    if workflow_matches:
        best_wf = max(workflow_matches, key=lambda w: w.get("occurrences", 0))
        steps = len(best_wf.get("pattern", "").split(" → "))
        if steps >= 3:
            score += 2.0
            reasons.append(f"consistent workflow ({steps} steps)")

    # Label quality (indicates clear intent)
    label = cluster.get("label", "")
    intent_words = {"fix", "add", "create", "implement", "update", "refactor", "test", "review", "debug", "deploy"}
    if any(w in label.lower() for w in intent_words):
        score += 1.0
        reasons.append("clear intent trigger")

    return {
        "type": "skill",
        "label": label,
        "score": round(score, 1),
        "reasons": reasons,
        "count": count,
        "sources": sources,
        "examples": cluster.get("example_prompts", [])[:3],
        "workflow": workflow_matches[0].get("pattern", "") if workflow_matches else "",
    }


def _score_subagent(cluster: dict, tool_data: dict) -> dict:
    """Score a prompt cluster as a subagent candidate."""
    score = 0.0
    reasons = []

    count = cluster.get("count", 0)
    label = cluster.get("label", "")
    examples = cluster.get("example_prompts", [])

    # Check for exploration-heavy terms
    explore_terms = {"find", "search", "understand", "explore", "look", "check", "investigate", "review", "analyze"}
    if any(w in label.lower() for w in explore_terms):
        score += 2.0
        reasons.append("exploration intent in label")

    # Check example prompts for research patterns
    research_keywords = 0
    for ex in examples:
        ex_lower = ex.lower()
        if any(w in ex_lower for w in explore_terms):
            research_keywords += 1
    if research_keywords >= 2:
        score += 1.5
        reasons.append(f"research keywords in {research_keywords} examples")

    if count >= 10:
        score += 1.5
        reasons.append(f"frequent ({count})")
    elif count >= 5:
        score += 0.5

    # Cross-source
    sources = cluster.get("sources", [])
    if len(sources) > 1:
        score += 0.5

    return {
        "type": "subagent",
        "label": label,
        "score": round(score, 1),
        "reasons": reasons,
        "count": count,
        "sources": sources,
        "examples": examples[:3],
    }


def _score_tool_pattern(ngram: dict) -> dict:
    """Score a tool n-gram as a reusable tool candidate."""
    score = 0.0
    reasons = []

    count = ngram.get("count", 0)
    sequence = ngram.get("sequence", "")
    steps = sequence.split(" → ")

    if count >= 50:
        score += 3.0
        reasons.append(f"very high frequency ({count})")
    elif count >= 20:
        score += 2.0
        reasons.append(f"high frequency ({count})")
    elif count >= 10:
        score += 1.0

    # Short, focused sequences score higher as tool candidates
    if len(steps) <= 3:
        score += 1.0
        reasons.append(f"focused ({len(steps)} steps)")

    # Mixed read+write patterns are useful atomic tools
    step_set = set(s.strip().lower() for s in steps)
    has_read = bool(step_set & {s.lower() for s in EXPLORATION_TOOLS})
    has_write = bool(step_set & {s.lower() for s in MUTATION_TOOLS})
    if has_read and has_write:
        score += 1.5
        reasons.append("read-then-write pattern")

    return {
        "type": "tool",
        "label": sequence,
        "score": round(score, 1),
        "reasons": reasons,
        "count": count,
    }


def run_classification(output_dir: Path) -> dict[str, list[dict]]:
    """Classify all findings into skill/subagent/tool candidates."""
    results: dict[str, list[dict]] = {"skills": [], "subagents": [], "tools": []}

    # Load data
    clusters_path = output_dir / "clusters.parquet"
    workflows_path = output_dir / "workflows.parquet"
    tool_freq_path = output_dir / "tool_frequency.parquet"

    clusters = pl.read_parquet(clusters_path) if clusters_path.exists() else pl.DataFrame()
    workflows = pl.read_parquet(workflows_path) if workflows_path.exists() else pl.DataFrame()
    tool_freq = pl.read_parquet(tool_freq_path) if tool_freq_path.exists() else pl.DataFrame()

    # Build tool frequency lookup
    freq_map = {}
    if len(tool_freq) > 0:
        for row in tool_freq.iter_rows(named=True):
            freq_map[row["tool_name"]] = row["count"]

    # Build workflow list
    workflow_list = []
    if len(workflows) > 0:
        workflow_list = workflows.to_dicts()

    # Score each cluster as skill and subagent candidate
    if len(clusters) > 0:
        for cluster in clusters.iter_rows(named=True):
            # Find matching workflows (naive: check if any workflow example overlaps)
            matching_workflows = []
            for wf in workflow_list:
                wf_prompts = wf.get("example_first_prompts", [])
                cluster_examples = cluster.get("example_prompts", [])
                # Simple overlap check
                if any(
                    any(cp[:30] in wp for wp in wf_prompts)
                    for cp in cluster_examples
                    if cp
                ):
                    matching_workflows.append(wf)

            skill = _score_skill(cluster, matching_workflows, freq_map)
            if skill["score"] >= 2.0:
                results["skills"].append(skill)

            subagent = _score_subagent(cluster, freq_map)
            if subagent["score"] >= 2.0:
                results["subagents"].append(subagent)

    # Score tool n-grams
    # Load from analyze_tools output if available
    tool_freq_by_source_path = output_dir / "tool_frequency_by_source.parquet"
    if tool_freq_by_source_path.exists():
        # Use bigrams and trigrams from the workflow patterns as tool candidates
        for wf in workflow_list:
            pattern = wf.get("pattern", "")
            steps = pattern.split(" → ")
            if 2 <= len(steps) <= 4:
                tool_candidate = _score_tool_pattern({
                    "sequence": pattern,
                    "count": wf.get("occurrences", 0),
                })
                if tool_candidate["score"] >= 2.0:
                    results["tools"].append(tool_candidate)

    # Sort by score
    for key in results:
        results[key].sort(key=lambda x: x["score"], reverse=True)
        results[key] = results[key][:20]  # Keep top 20

    return results
