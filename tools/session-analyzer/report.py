"""Phase 4: Rich terminal + markdown report generation."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

import polars as pl
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.text import Text


def _fmt_count(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}K"
    return str(n)


def render_terminal_report(
    output_dir: Path,
    extract_stats: dict | None = None,
    tool_results: dict | None = None,
    classifications: dict | None = None,
) -> None:
    """Print a rich terminal report."""
    console = Console()

    console.print()
    console.print(Panel.fit(
        "[bold cyan]Session Analyzer Report[/bold cyan]",
        subtitle=datetime.now().strftime("%Y-%m-%d %H:%M"),
    ))

    # ── Summary Stats ───────────────────────────────────────────────

    if extract_stats:
        table = Table(title="Extraction Summary", show_header=True)
        table.add_column("Metric", style="bold")
        table.add_column("Value", justify="right")

        table.add_row("Total files processed", _fmt_count(extract_stats.get("total_files", 0)))
        table.add_row("  Claude files", _fmt_count(extract_stats.get("claude_files", 0)))
        table.add_row("  Codex files", _fmt_count(extract_stats.get("codex_files", 0)))
        table.add_row("  Lemon files", _fmt_count(extract_stats.get("lemon_files", 0)))
        table.add_row("User prompts", _fmt_count(extract_stats.get("prompts", 0)))
        table.add_row("Tool calls", _fmt_count(extract_stats.get("tool_calls", 0)))
        table.add_row("Sessions", _fmt_count(extract_stats.get("sessions", 0)))

        console.print(table)
        console.print()

    # ── Prompt Clusters ─────────────────────────────────────────────

    clusters_path = output_dir / "clusters.parquet"
    if clusters_path.exists():
        clusters = pl.read_parquet(clusters_path)
        if len(clusters) > 0:
            table = Table(title="Top Prompt Clusters", show_header=True)
            table.add_column("#", justify="right", style="dim")
            table.add_column("Label", style="bold")
            table.add_column("Count", justify="right")
            table.add_column("Sources")
            table.add_column("Example Prompt", max_width=60)

            for i, row in enumerate(clusters.head(15).iter_rows(named=True)):
                examples = row.get("example_prompts", [])
                example = examples[0][:60] + "..." if examples and len(examples[0]) > 60 else (examples[0] if examples else "")
                sources = ", ".join(row.get("sources", []))
                table.add_row(
                    str(i + 1),
                    row["label"],
                    str(row["count"]),
                    sources,
                    example,
                )

            console.print(table)
            console.print()

    # ── Tool Usage ──────────────────────────────────────────────────

    if tool_results and "frequency" in tool_results:
        freq = tool_results["frequency"]
        if len(freq) > 0:
            table = Table(title="Top Tools by Usage", show_header=True)
            table.add_column("#", justify="right", style="dim")
            table.add_column("Tool", style="bold")
            table.add_column("Count", justify="right")

            for i, row in enumerate(freq.head(20).iter_rows(named=True)):
                table.add_row(str(i + 1), row["tool_name"], _fmt_count(row["count"]))

            console.print(table)
            console.print()

    # ── Tool Sequences ──────────────────────────────────────────────

    if tool_results and "ngrams" in tool_results:
        ngrams = tool_results["ngrams"]
        for n in (2, 3):
            if n in ngrams and ngrams[n]:
                table = Table(title=f"Top {n}-gram Tool Sequences", show_header=True)
                table.add_column("#", justify="right", style="dim")
                table.add_column("Sequence", style="bold")
                table.add_column("Count", justify="right")

                for i, item in enumerate(ngrams[n][:15]):
                    table.add_row(str(i + 1), item["sequence"], str(item["count"]))

                console.print(table)
                console.print()

    # ── Classifications ─────────────────────────────────────────────

    if classifications:
        for category, label_name in [("skills", "Skill"), ("subagents", "Subagent"), ("tools", "Tool")]:
            items = classifications.get(category, [])
            if not items:
                continue

            table = Table(title=f"Top {label_name} Candidates", show_header=True)
            table.add_column("#", justify="right", style="dim")
            table.add_column("Label", style="bold", max_width=40)
            table.add_column("Score", justify="right")
            table.add_column("Count", justify="right")
            table.add_column("Reasons", max_width=50)

            for i, item in enumerate(items[:10]):
                table.add_row(
                    str(i + 1),
                    item["label"],
                    str(item["score"]),
                    str(item.get("count", "")),
                    "; ".join(item.get("reasons", [])),
                )

            console.print(table)
            console.print()


def generate_markdown_report(
    output_dir: Path,
    extract_stats: dict | None = None,
    tool_results: dict | None = None,
    classifications: dict | None = None,
) -> Path:
    """Generate a detailed markdown report. Returns path to report file."""
    report_path = output_dir / "session-analysis-report.md"
    lines: list[str] = []

    lines.append("# Session Analysis Report")
    lines.append(f"\nGenerated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")

    # ── Summary ─────────────────────────────────────────────────────

    lines.append("## Summary Statistics\n")
    if extract_stats:
        lines.append("| Metric | Value |")
        lines.append("|--------|-------|")
        lines.append(f"| Total files | {extract_stats.get('total_files', 0):,} |")
        lines.append(f"| Claude files | {extract_stats.get('claude_files', 0):,} |")
        lines.append(f"| Codex files | {extract_stats.get('codex_files', 0):,} |")
        lines.append(f"| Lemon files | {extract_stats.get('lemon_files', 0):,} |")
        lines.append(f"| User prompts | {extract_stats.get('prompts', 0):,} |")
        lines.append(f"| Tool calls | {extract_stats.get('tool_calls', 0):,} |")
        lines.append(f"| Sessions | {extract_stats.get('sessions', 0):,} |")
        lines.append("")

    # ── Prompt Clusters ─────────────────────────────────────────────

    clusters_path = output_dir / "clusters.parquet"
    if clusters_path.exists():
        clusters = pl.read_parquet(clusters_path)
        if len(clusters) > 0:
            lines.append("## Prompt Clusters\n")
            for row in clusters.iter_rows(named=True):
                lines.append(f"### Cluster: {row['label']} ({row['count']} prompts)\n")
                lines.append(f"**Sources:** {', '.join(row.get('sources', []))}\n")

                terms = row.get("top_terms", [])
                if terms:
                    lines.append(f"**Top terms:** {', '.join(terms[:8])}\n")

                examples = row.get("example_prompts", [])
                if examples:
                    lines.append("**Example prompts:**\n")
                    for ex in examples[:5]:
                        # Truncate long examples
                        ex_short = ex[:150] + "..." if len(ex) > 150 else ex
                        lines.append(f"- {ex_short}")
                    lines.append("")

    # ── Tool Usage ──────────────────────────────────────────────────

    if tool_results:
        lines.append("## Tool Usage Analysis\n")

        freq = tool_results.get("frequency")
        if freq is not None and len(freq) > 0:
            lines.append("### Overall Tool Frequency\n")
            lines.append("| Rank | Tool | Count |")
            lines.append("|------|------|-------|")
            for i, row in enumerate(freq.head(25).iter_rows(named=True)):
                lines.append(f"| {i + 1} | {row['tool_name']} | {row['count']:,} |")
            lines.append("")

        # N-grams
        ngrams = tool_results.get("ngrams", {})
        for n, label in [(2, "Bigrams"), (3, "Trigrams"), (4, "4-grams")]:
            items = ngrams.get(n, [])
            if items:
                lines.append(f"### Tool {label}\n")
                lines.append("| Rank | Sequence | Count |")
                lines.append("|------|----------|-------|")
                for i, item in enumerate(items[:20]):
                    lines.append(f"| {i + 1} | {item['sequence']} | {item['count']:,} |")
                lines.append("")

        # Co-occurrence
        cooccur = tool_results.get("cooccurrence")
        if cooccur is not None and len(cooccur) > 0:
            lines.append("### Tool Co-occurrence (same turn)\n")
            lines.append("| Tool A | Tool B | Count |")
            lines.append("|--------|--------|-------|")
            for row in cooccur.head(20).iter_rows(named=True):
                lines.append(f"| {row['tool_a']} | {row['tool_b']} | {row['count']:,} |")
            lines.append("")

    # ── Workflow Patterns ───────────────────────────────────────────

    workflows_path = output_dir / "workflows.parquet"
    if workflows_path.exists():
        workflows = pl.read_parquet(workflows_path)
        if len(workflows) > 0:
            lines.append("## Workflow Patterns\n")
            lines.append("| Rank | Pattern | Occurrences | Sessions | Sources |")
            lines.append("|------|---------|-------------|----------|---------|")
            for i, row in enumerate(workflows.head(30).iter_rows(named=True)):
                sources = ", ".join(row.get("sources", []))
                lines.append(
                    f"| {i + 1} | {row['pattern']} | "
                    f"{row['occurrences']:,} | {row['distinct_sessions']} | {sources} |"
                )
            lines.append("")

    # ── Classifications ─────────────────────────────────────────────

    if classifications:
        lines.append("## Recommended Candidates\n")

        for category, title, desc in [
            ("skills", "Skill Candidates", "High-level user-facing workflows that should become reusable skills"),
            ("subagents", "Subagent Candidates", "Delegatable research/exploration tasks"),
            ("tools", "Tool Candidates", "Reusable atomic tool operations"),
        ]:
            items = classifications.get(category, [])
            if not items:
                continue

            lines.append(f"### {title}\n")
            lines.append(f"*{desc}*\n")

            for i, item in enumerate(items[:15], 1):
                lines.append(f"**{i}. {item['label']}** (score: {item['score']})")
                if item.get("reasons"):
                    lines.append(f"  - Reasons: {'; '.join(item['reasons'])}")
                if item.get("count"):
                    lines.append(f"  - Frequency: {item['count']}")
                if item.get("sources"):
                    lines.append(f"  - Sources: {', '.join(item['sources'])}")
                if item.get("examples"):
                    lines.append("  - Examples:")
                    for ex in item["examples"][:3]:
                        ex_short = ex[:120] + "..." if len(ex) > 120 else ex
                        lines.append(f"    - {ex_short}")
                if item.get("workflow"):
                    lines.append(f"  - Workflow: {item['workflow']}")
                lines.append("")

    report_text = "\n".join(lines)
    report_path.write_text(report_text)
    return report_path
