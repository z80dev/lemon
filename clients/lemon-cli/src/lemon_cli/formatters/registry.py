from typing import Callable
from lemon_cli.formatters.base import FormattedResult


class FormatterRegistry:
    def __init__(self):
        self._formatters: dict[str, Callable[[str], FormattedResult]] = {}

    def register(self, tool_name: str, formatter_fn: Callable[[str], FormattedResult]):
        self._formatters[tool_name.lower()] = formatter_fn

    def format_result(self, tool_name: str, content: str) -> FormattedResult:
        fn = self._formatters.get(tool_name.lower())
        if fn:
            try:
                return fn(content)
            except Exception:
                pass
        # Fallback
        summary = (content[:100] + "...") if len(content) > 100 else content
        return FormattedResult(summary=summary or "(no output)")


def build_default_registry() -> FormatterRegistry:
    from lemon_cli.formatters import bash, read, edit, grep, write, glob, web, task

    registry = FormatterRegistry()

    for name in ("bash", "terminal"):
        registry.register(name, bash.format_result)

    for name in ("read", "read_file"):
        registry.register(name, read.format_result)

    for name in ("edit", "edit_file"):
        registry.register(name, edit.format_result)

    for name in ("grep", "search"):
        registry.register(name, grep.format_result)

    for name in ("write", "write_file"):
        registry.register(name, write.format_result)

    for name in ("glob", "find", "ls"):
        registry.register(name, glob.format_result)

    for name in ("web_search", "websearch", "web_fetch", "webfetch"):
        registry.register(name, web.format_result)

    for name in ("task", "todo", "process"):
        registry.register(name, task.format_result)

    return registry
