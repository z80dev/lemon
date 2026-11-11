def latest(events):
    winners = {}
    for event in events:
        previous = winners.get(event.event_id)
        if previous is None or event.revision >= previous.revision:
            winners[event.event_id] = event
    return winners.values()
