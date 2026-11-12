# Flights

The upstream-read helper shares requests by key. `core.py` is the caller-facing
wrapper; `book.py` maintains the task registry. The current caller-owned cleanup
works for simple reads but needs correct cancellation and completion ownership.

Run: `python3 -m unittest discover -s tests -v`
