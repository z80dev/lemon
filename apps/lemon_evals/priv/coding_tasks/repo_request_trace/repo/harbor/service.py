from . import schema, tenants, projects, calendar, currency, money, fees, keys, idempotency, budget, events, journal
def reserve(state, tenant, body):
    data = schema.require(body)
    profile = tenants.get(tenant)
    project = projects.resolve(tenant, data['project'])
    day = calendar.parse_day(data['day'])
    unit = currency.normalize(data['currency'], profile)
    amount = money.cents(data['amount'])
    fee = fees.calculate(amount)
    key = keys.reservation(tenant, project, day, data['request_id'])
    old = idempotency.lookup(state, key)
    if old is not None:
        return old
    budget.check(state, amount + fee)
    return journal.commit(state, events.build(key, tenant, project, day, unit, amount, fee))
