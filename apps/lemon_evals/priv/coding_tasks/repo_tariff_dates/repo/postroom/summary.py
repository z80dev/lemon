def totals(results):
    good=[r['result']['quote'] for r in results if r['status']==200]
    return {'count':len(good),'cents':sum(r['total_cents'] for r in good)}
