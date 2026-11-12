from copy import deepcopy
from types import MappingProxyType

_CACHE = {}


def compile_policy(name, spec):
    allowed = frozenset(spec.get("allow", []))
    denied = frozenset(spec.get("deny", []))
    key = (name, allowed, denied)
    if key not in _CACHE:
        _CACHE[key] = MappingProxyType({"allow": allowed, "deny": denied})
    return _CACHE[key]


class Engine:
    def __init__(self, config):
        self.config = deepcopy(config)

    def allows(self, policy, role, extra_roles=()):
        if policy not in self.config:
            return False
        compiled = compile_policy(policy, self.config[policy])
        return role not in compiled["deny"] and (
            role in compiled["allow"] or role in extra_roles
        )
