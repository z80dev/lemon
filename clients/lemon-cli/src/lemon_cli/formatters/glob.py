from lemon_cli.formatters.base import FormattedResult


def format_result(content: str) -> FormattedResult:
    """Format glob/find/ls tool result."""
    if not content:
        return FormattedResult(summary="no files found")

    files = [l for l in content.splitlines() if l.strip()]
    file_count = len(files)
    summary = f"{file_count} file{'s' if file_count != 1 else ''}"
    return FormattedResult(summary=summary, detail=None)
