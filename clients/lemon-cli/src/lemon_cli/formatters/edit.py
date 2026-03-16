from lemon_cli.formatters.base import FormattedResult


def format_result(content: str) -> FormattedResult:
    """Format edit file tool result."""
    if not content:
        return FormattedResult(summary="edited file")

    # Content is typically a confirmation or diff summary
    summary = content.strip()[:120]
    if len(content.strip()) > 120:
        summary += "..."
    return FormattedResult(summary=summary)
