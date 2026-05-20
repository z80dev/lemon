from lemon_cli.formatters.base import FormattedResult


def format_result(content: str) -> FormattedResult:
    """Format grep/search tool result."""
    if not content:
        return FormattedResult(summary="no matches found")

    lines = [line for line in content.splitlines() if line.strip()]
    match_count = len(lines)
    summary = f"{match_count} match{'es' if match_count != 1 else ''}"
    detail = content if match_count > 0 else None
    return FormattedResult(summary=summary, detail=detail)
