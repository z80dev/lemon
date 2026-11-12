from pathlib import Path
rows=Path('data.csv').read_text().splitlines()
print('TOTAL=' + str(sum(int(row.split(',')[0]) for row in rows)))
