import queue
import time


class OverlayBase:
    """Base class for interactive overlays using queue-based blocking."""

    def __init__(self, timeout: float = 120.0):
        self._result_queue: queue.Queue = queue.Queue(maxsize=1)
        self._deadline = time.monotonic() + timeout
        self._cancelled = False

    def wait_for_result(self) -> dict:
        """Block until user responds or timeout. Returns {result, error}."""
        while True:
            try:
                return self._result_queue.get(timeout=1.0)
            except queue.Empty:
                if time.monotonic() > self._deadline:
                    return {"result": None, "error": "Overlay timed out"}
                if self._cancelled:
                    return {"result": None, "error": "Cancelled"}
                continue

    def submit(self, result):
        self._result_queue.put({"result": result, "error": None})

    def cancel(self):
        self._cancelled = True
