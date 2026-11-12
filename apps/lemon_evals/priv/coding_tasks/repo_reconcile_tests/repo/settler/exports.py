import csv
def csv_totals(stream, totals):
    writer=csv.writer(stream)
    writer.writerow(['account','total'])
    writer.writerows(totals.items())
