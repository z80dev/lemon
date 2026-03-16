from dataclasses import dataclass


@dataclass
class FormattedResult:
    summary: str
    detail: str | None = None
    is_error: bool = False
