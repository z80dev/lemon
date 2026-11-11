import json
def write_totals(stream, totals):
    for account, total in totals.items():
        stream.write(json.dumps({'account':account,'total':total},sort_keys=True)+'\n')
