from lemon_cli.tui.overlays.base import OverlayBase
from lemon_cli.tui.overlays.select import SelectOverlay
from lemon_cli.tui.overlays.confirm import ConfirmOverlay
from lemon_cli.tui.overlays.input_overlay import InputOverlay
from lemon_cli.tui.overlays.editor import EditorOverlay


def handle_ui_request(request, app) -> dict | None:
    """Dispatch a ui_request to the appropriate overlay and return result."""
    method = request.method if hasattr(request, "method") else request.get("method", "")
    params = request.params if hasattr(request, "params") else request.get("params", {})

    if isinstance(params, dict):
        params_dict = params
    else:
        params_dict = {k: v for k, v in vars(params).items() if not k.startswith("_")}

    if method == "select":
        overlay = SelectOverlay(params_dict)
        overlay.confirm()
        return overlay.wait_for_result()

    elif method == "confirm":
        overlay = ConfirmOverlay(params_dict)
        overlay.confirm(True)
        return overlay.wait_for_result()

    elif method == "input":
        overlay = InputOverlay(params_dict)
        overlay.submit_value("")
        return overlay.wait_for_result()

    elif method == "editor":
        overlay = EditorOverlay(params_dict)
        overlay.launch()
        return overlay.wait_for_result()

    return None


__all__ = [
    "OverlayBase",
    "SelectOverlay",
    "ConfirmOverlay",
    "InputOverlay",
    "EditorOverlay",
    "handle_ui_request",
]
