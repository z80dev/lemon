from .errors import Rejection
PROJECTS = {('team-birch','west'): ('harbor-west', True), ('team-birch','old'): ('harbor-old', False)}
def resolve(tenant, alias):
    project = PROJECTS.get((tenant, alias))
    if project is None:
        raise Rejection(404, 'PROJECT_UNKNOWN', 'harbor.projects.resolve')
    if not project[1]:
        raise Rejection(423, 'PROJECT_CLOSED', 'harbor.projects.resolve')
    return project[0]
