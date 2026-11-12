from datetime import date
from .errors import Rejection
def parse_day(raw):
    try:
        return date.fromisoformat(raw).isoformat()
    except (ValueError, TypeError):
        raise Rejection(400, 'DAY_INVALID', 'harbor.calendar.parse_day')
