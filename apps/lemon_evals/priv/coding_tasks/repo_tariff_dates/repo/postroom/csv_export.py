import csv
def write(stream,results):
    writer=csv.writer(stream);writer.writerow(['reference','cents'])
    for result in results:
        if result['status']==200:
            value=result['result'];writer.writerow([value['reference'],value['quote']['total_cents']])
