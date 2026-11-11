def reservation(tenant, project, day, request_id):
    return ':'.join((tenant, project, day, request_id))
