import csv,json
def orders(stream):
    for row in csv.DictReader(stream):
        yield {'reference':row['reference'],'depot':int(row['depot']),'shipping_date':row['shipping_date'],
               'billed_on':row['billed_on'],'items':json.loads(row['items']),'address':json.loads(row['address'])}
