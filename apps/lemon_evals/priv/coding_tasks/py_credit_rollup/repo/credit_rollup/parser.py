"""Read ledger exports from finance's CSV feed."""
from .models import Transaction


class RowError(ValueError):
    def __init__(self, record, line, reason):
        self.record = record
        self.line = line
        self.reason = reason
        super().__init__(f"record {record}, line {line}: {reason}")


def transactions(source):
    header = source.readline().rstrip("\r\n").split(",")
    if header != ["account", "currency", "kind", "amount", "memo"]:
        raise RowError(0, 1, "expected header account,currency,kind,amount,memo")
    for number, line in enumerate(source, 1):
        if not line.strip():
            continue
        fields = line.rstrip("\r\n").split(",")
        if len(fields) != 5:
            raise RowError(number, number + 1, "expected 5 fields")
        account, currency, kind, amount, memo = fields
        yield Transaction(account.strip(), currency.strip(), kind.strip(),
                          round(float(amount) * 100))
