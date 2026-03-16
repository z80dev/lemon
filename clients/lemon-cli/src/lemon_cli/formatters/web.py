from lemon_cli.formatters.base import FormattedResult


def format_result(content: str) -> FormattedResult:
    """Format WebFetch/WebSearch tool result."""
    if not content:
        return FormattedResult(summary="(no content)")

    lines = content.splitlines()
    line_count = len(lines)
    summary = f"{line_count} line{'s' if line_count != 1 else ''} fetched"
    preview = lines[0][:100] if lines else ""
    detail = content if len(content) > 200 else None
    if preview:
        summary = f"{preview} ({line_count} lines)"
    return FormattedResult(summary=summary, detail=detail)
