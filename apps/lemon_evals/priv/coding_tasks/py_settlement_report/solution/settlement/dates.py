from datetime import datetime
from zoneinfo import ZoneInfo

def in_month(timestamp, month, zone):
    local = datetime.fromisoformat(timestamp).astimezone(ZoneInfo(zone))
    return local.strftime('%Y-%m') == month
