"""CLI entry point for session-analyzer."""

from __future__ import annotations

from pathlib import Path

import click
from rich.console import Console

console = Console()

DEFAULT_OUTPUT = Path(__file__).parent / "output"


@click.group()
def cli():
    """Mine AI session data for skill/subagent/tool patterns."""
    pass


@cli.command()
@click.option("--output-dir", type=click.Path(), default=str(DEFAULT_OUTPUT), help="Output directory for parquet + reports")
@click.option("--max-files", type=int, default=None, help="Limit files processed (for testing)")
@click.option("--workers", type=int, default=None, help="Override CPU count for multiprocessing")
@click.option("--skip-lemon", is_flag=True, help="Skip Lemon sessions")
def extract(output_dir: str, max_files: int | None, workers: int | None, skip_lemon: bool):
    """Phase 1: Extract and normalize JSONL → parquet."""
    from extract import run_extraction

    out = Path(output_dir)
    stats = run_extraction(out, max_files=max_files, workers=workers, skip_lemon=skip_lemon)

    console.print(f"\n[bold green]Extraction complete![/bold green]")
    for k, v in stats.items():
        console.print(f"  {k}: {v:,}")


@cli.command()
@click.option("--output-dir", type=click.Path(), default=str(DEFAULT_OUTPUT))
def analyze(output_dir: str):
    """Phase 2: Run all analyses (prompts, tools, workflows)."""
    out = Path(output_dir)

    console.print("[bold blue]Running prompt clustering...[/bold blue]")
    from analyze_prompts import run_prompt_clustering
    clusters = run_prompt_clustering(out)
    console.print(f"  Found {len(clusters)} clusters")

    console.print("[bold blue]Running tool analysis...[/bold blue]")
    from analyze_tools import run_tool_analysis
    tool_results = run_tool_analysis(out)
    freq = tool_results.get("frequency")
    console.print(f"  Found {len(freq) if freq is not None else 0} unique tools")

    console.print("[bold blue]Running workflow mining...[/bold blue]")
    from analyze_workflows import run_workflow_analysis
    workflows = run_workflow_analysis(out)
    console.print(f"  Found {len(workflows)} workflow patterns")

    console.print("[bold green]Analysis complete![/bold green]")


@cli.command()
@click.option("--output-dir", type=click.Path(), default=str(DEFAULT_OUTPUT))
def classify(output_dir: str):
    """Phase 3: Classify findings → skill/subagent/tool candidates."""
    out = Path(output_dir)

    from classify import run_classification
    results = run_classification(out)

    console.print("[bold green]Classification complete![/bold green]")
    for category, items in results.items():
        console.print(f"  {category}: {len(items)} candidates")


@cli.command()
@click.option("--output-dir", type=click.Path(), default=str(DEFAULT_OUTPUT))
def report(output_dir: str):
    """Phase 4: Generate terminal + markdown reports."""
    out = Path(output_dir)

    from analyze_tools import run_tool_analysis
    from classify import run_classification
    from report import render_terminal_report, generate_markdown_report

    tool_results = run_tool_analysis(out)
    classifications = run_classification(out)

    render_terminal_report(out, tool_results=tool_results, classifications=classifications)
    report_path = generate_markdown_report(out, tool_results=tool_results, classifications=classifications)
    console.print(f"\n[bold green]Report saved to {report_path}[/bold green]")


@cli.command()
@click.option("--output-dir", type=click.Path(), default=str(DEFAULT_OUTPUT), help="Output directory")
@click.option("--max-files", type=int, default=None, help="Limit files processed (for testing)")
@click.option("--workers", type=int, default=None, help="Override CPU count")
@click.option("--skip-lemon", is_flag=True, help="Skip Lemon sessions")
def run(output_dir: str, max_files: int | None, workers: int | None, skip_lemon: bool):
    """Run full pipeline: extract → analyze → classify → report."""
    out = Path(output_dir)

    # Phase 1
    console.print("\n[bold cyan]═══ Phase 1: Extraction ═══[/bold cyan]")
    from extract import run_extraction
    stats = run_extraction(out, max_files=max_files, workers=workers, skip_lemon=skip_lemon)
    for k, v in stats.items():
        console.print(f"  {k}: {v:,}")

    # Phase 2
    console.print("\n[bold cyan]═══ Phase 2: Analysis ═══[/bold cyan]")

    console.print("[blue]Clustering prompts...[/blue]")
    from analyze_prompts import run_prompt_clustering
    clusters = run_prompt_clustering(out)
    console.print(f"  {len(clusters)} clusters")

    console.print("[blue]Analyzing tools...[/blue]")
    from analyze_tools import run_tool_analysis
    tool_results = run_tool_analysis(out)
    console.print(f"  {len(tool_results.get('frequency', []))} unique tools")

    console.print("[blue]Mining workflows...[/blue]")
    from analyze_workflows import run_workflow_analysis
    workflows = run_workflow_analysis(out)
    console.print(f"  {len(workflows)} workflow patterns")

    # Phase 3
    console.print("\n[bold cyan]═══ Phase 3: Classification ═══[/bold cyan]")
    from classify import run_classification
    classifications = run_classification(out)
    for category, items in classifications.items():
        console.print(f"  {category}: {len(items)} candidates")

    # Phase 4
    console.print("\n[bold cyan]═══ Phase 4: Report ═══[/bold cyan]")
    from report import render_terminal_report, generate_markdown_report

    render_terminal_report(out, extract_stats=stats, tool_results=tool_results, classifications=classifications)
    report_path = generate_markdown_report(out, extract_stats=stats, tool_results=tool_results, classifications=classifications)
    console.print(f"\n[bold green]Full report: {report_path}[/bold green]")


if __name__ == "__main__":
    cli()
