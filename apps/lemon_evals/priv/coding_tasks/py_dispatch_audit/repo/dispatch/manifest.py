"""Load a dispatch snapshot into account policies and shipment records."""
import json
from pathlib import Path
from .models import Shipment


def load(path):
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    shipments = [Shipment(shipment_id=row["id"], account=row["account"],
                          status=row["status"], zone=row["zone"],
                          actual_g=row["actual_g"], dimensions_cm=tuple(row["dimensions_cm"]),
                          fragile=row["fragile"]) for row in payload["shipments"]]
    rebates = {account: policy["rebate_percent"] for account, policy in payload["accounts"].items()}
    return shipments, rebates
