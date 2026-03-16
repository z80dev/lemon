from lemon_cli.formatters.base import FormattedResult


def format_result(content: str) -> FormattedResult:
    """Format read file tool result."""
    if not content:
        return FormattedResult(summary="(empty file)")

    lines = content.splitlines()
    line_count = len(lines)
    summary = f"{line_count} line{'s' if line_count != 1 else ''}"
    return FormattedResult(summary=summary, detail=None)
