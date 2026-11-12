from .formatting import money
from .receipt import receipt
def render(totals):
    lines=[f'{name}: {money(value)}' for name,value in totals.items()]
    lines.append(f"Net: {money(receipt(totals)['net'])}")
    return '\n'.join(lines)
