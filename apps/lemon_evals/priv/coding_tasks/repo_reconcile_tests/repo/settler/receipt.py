def receipt(totals):
    return {'accounts':len(totals),'net':sum(totals.values())}
