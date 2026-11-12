from .revisions import latest

def balances(events, checkpoints):
    winners = list(latest(events))
    return [sum(event.delta for event in winners
                if event.sku == point.sku and event.at <= point.at)
            for point in checkpoints]
