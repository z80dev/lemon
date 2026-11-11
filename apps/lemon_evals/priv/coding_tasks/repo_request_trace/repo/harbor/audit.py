def record(state, result):
    state.audit.append({'status': result['status'], 'code': result.get('code', 'OK')})
