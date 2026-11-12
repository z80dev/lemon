import csv
from pathlib import Path

with Path('data.csv').open(newline='') as source:
    rows = csv.DictReader(source)
    total = sum(int(row['amount']) for row in rows)
print('TOTAL=' + str(total))
