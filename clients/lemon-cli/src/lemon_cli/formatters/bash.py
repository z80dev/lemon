from lemon_cli.formatters.base import FormattedResult

_MAX_OUTPUT = 500


def format_result(content: str) -> FormattedResult:
    """Format bash/terminal tool result."""
    if not content:
        return FormattedResult(summary="(no output)")

    lines = content.splitlines()
    command = None
    output_lines = lines

    # Try to extract command from first line if it looks like a command echo
    if lines and lines[0].startswith("$ "):
        command = lines[0][2:].strip()
        output_lines = lines[1:]

    output = "\n".join(output_lines)
    truncated = len(output) > _MAX_OUTPUT
    if truncated:
        output = output[:_MAX_OUTPUT] + "..."

    if command:
        summary = f"$ {command}"
        detail = output if output else None
    else:
        summary = output[:100] + ("..." if len(output) > 100 else "")
        detail = output if truncated else None

    return FormattedResult(summary=summary, detail=detail)
