from copy import deepcopy

_CACHE = {}


def compile_policy(name, spec):
    if name not in _CACHE:
        _CACHE[name] = {
            "allow": set(spec.get("allow", [])),
            "deny": set(spec.get("deny", [])),
        }
    return _CACHE[name]


class Engine:
    def __init__(self, config):
        self.config = deepcopy(config)

    def allows(self, policy, role, extra_roles=()):
        if policy not in self.config:
            return False
        compiled = compile_policy(policy, self.config[policy])
        allowed = compiled["allow"]
        allowed.update(extra_roles)
        return role in allowed and role not in compiled["deny"]
