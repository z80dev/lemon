from .errors import Rejection
def check(state, charge):
    if state.used + charge > state.limit:
        raise Rejection(409, 'BUDGET_LIMIT', 'harbor.budget.check')
