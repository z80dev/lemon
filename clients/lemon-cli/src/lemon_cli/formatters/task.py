from lemon_cli.formatters.base import FormattedResult


def format_result(content: str) -> FormattedResult:
    """Format task/todo/process tool result."""
    if not content:
        return FormattedResult(summary="(task complete)")

    summary = content.strip()[:120]
    if len(content.strip()) > 120:
        summary += "..."
    return FormattedResult(summary=summary)
