from lemon_cli.tui.overlays.base import OverlayBase


class InputOverlay(OverlayBase):
    def __init__(self, params: dict, timeout: float = 120.0):
        super().__init__(timeout)
        self.title = params.get("title", "Enter value")
        self.placeholder = params.get("placeholder", "")
        self.value = ""

    def render(self) -> str:
        placeholder_str = f" ({self.placeholder})" if self.placeholder else ""
        return f"  {self.title}{placeholder_str}\n  > {self.value}_"

    def submit_value(self, text: str):
        self.submit(text)
