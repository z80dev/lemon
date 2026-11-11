# Stock checkpoints

Warehouse reconciliation asks for many historical stock balances at once. Movements are append-only revisions of globally named events; checkpoints report the inventory at inclusive integer timestamps. `stock.history.balances` currently computes reliable small-batch answers, but the nightly reconciliation job scales badly. No external dependencies.

Run visible checks with `python3 -m unittest discover -s tests -v`.
