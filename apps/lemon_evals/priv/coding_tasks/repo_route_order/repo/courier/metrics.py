def summarize(results):
    good=[r for r in results if 'cents' in r]
    return {'quoted':len(good),'cents':sum(r['cents'] for r in good)}
