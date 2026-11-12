def summary(state):
    return {'events': len(state.events), 'used': state.used, 'remaining': state.limit-state.used,
            'audit_statuses': [item['status'] for item in state.audit]}
