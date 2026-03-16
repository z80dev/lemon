from dataclasses import dataclass


@dataclass
class CumulativeUsage:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    total_cost: float = 0.0

    def update_from_usage(self, usage: dict):
        self.input_tokens += usage.get("input_tokens", 0)
        self.output_tokens += usage.get("output_tokens", 0)
        self.cache_read_tokens += usage.get("cache_read_tokens", 0)
        self.cache_write_tokens += usage.get("cache_write_tokens", 0)
        self.total_cost += usage.get("total_cost", 0.0)

    @property
    def total_tokens(self) -> int:
        return self.input_tokens + self.output_tokens

    def format_summary(self) -> str:
        return (f"In: {_fmt_tokens(self.input_tokens)} | "
                f"Out: {_fmt_tokens(self.output_tokens)} | "
                f"Cost: ${self.total_cost:.4f}")


def _fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)
