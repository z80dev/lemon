"""Strict CSV import with logical record and physical start-line errors."""
import csv
import re
from decimal import Decimal, localcontext
from .models import Transaction

HEADER = ["account", "currency", "kind", "amount", "memo"]
AMOUNT = re.compile(r"[0-9]+(?:\.[0-9]{1,2})?\Z")
CURRENCY = re.compile(r"[A-Z]{3}\Z")


class RowError(ValueError):
    def __init__(self, record, line, reason):
        self.record = record
        self.line = line
        self.reason = reason
        super().__init__(f"record {record}, line {line}: {reason}")


def _cents(value):
    if not AMOUNT.fullmatch(value):
        raise ValueError("invalid amount")
    number = Decimal(value)
    if number > Decimal("999999999999.99"):
        raise ValueError("invalid amount")
    with localcontext() as context:
        context.prec = max(28, len(value) + 2)
        return int(number * 100)


def transactions(source):
    reader = csv.reader(source, strict=True)
    try:
        header = next(reader, None)
    except csv.Error:
        raise RowError(0, 1, "invalid CSV") from None
    if header != HEADER:
        raise RowError(0, 1, "expected header account,currency,kind,amount,memo")
    record = 0
    while True:
        start_line = reader.line_num + 1
        try:
            fields = next(reader)
        except StopIteration:
            return
        except csv.Error:
            raise RowError(record + 1, start_line, "invalid CSV") from None
        if not fields:
            continue
        record += 1
        reason = None
        if len(fields) != 5:
            reason = "expected 5 fields"
        else:
            account, currency, kind, amount = (field.strip() for field in fields[:4])
            if not account:
                reason = "account is empty"
            elif not CURRENCY.fullmatch(currency):
                reason = "invalid currency"
            elif kind not in ("sale", "refund"):
                reason = "invalid kind"
            else:
                try:
                    cents = _cents(amount)
                except ValueError:
                    reason = "invalid amount"
        if reason:
            raise RowError(record, start_line, reason)
        yield Transaction(account, currency, kind, cents)
