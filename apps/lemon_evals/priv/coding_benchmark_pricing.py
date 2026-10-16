"""List-price equivalent spend for benchmark trials, computed offline from the model catalog.

Nothing here calls a provider or reads a credential. Prices are the public list prices bundled in
`apps/lemon_ai/priv/models/*.json` (USD per million tokens) multiplied by a trial's recorded token
counters. The result is **not billed spend**: subscription plans, discounts and provider-side
cache behavior are not modeled.
"""
import hashlib
import json
from pathlib import Path

LABEL = 'list-price equivalent, not billed'
UNIT = 'USD per 1,000,000 tokens'
# Lemon's usage `inputTokens` excludes cache reads and writes, so the four counters are disjoint.
COUNTERS = (('uncached_input_tokens', 'input'), ('cached_input_tokens', 'cache_read'),
            ('cache_write_tokens', 'cache_write'), ('output_tokens', 'output'))

# Provider -> where its public list price lives and which credential the isolated runtime may receive.
PROVIDERS = {
    'openai-codex': {'catalog': 'open_ai.json', 'catalog_provider': 'openai',
                     'credential_env': 'OPENAI_CODEX_API_KEY',
                     'basis': 'OpenAI API list price for the same model (the Codex route is not priced separately)'},
    'zai': {'catalog': 'zai.json', 'catalog_provider': 'zai',
            'credential_env': 'ZAI_API_KEY', 'basis': 'Z.AI catalog list price for the same model'},
}
CATALOG_DIRECTORY = Path('apps') / 'lemon_ai' / 'priv' / 'models'


def parse_provider_model(value):
    """`provider:model` for a supported provider; raises ValueError otherwise."""
    provider, separator, model = value.partition(':')
    if not separator or provider not in PROVIDERS or not model:
        raise ValueError('supported provider:model required (' + ', '.join(sorted(PROVIDERS)) + ')')
    return provider, model


def _price(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0 else None


def pricing_basis(provider, model, root):
    """Catalog price record for one provider/model, with the file digest that identifies the catalog."""
    if provider not in PROVIDERS:
        raise ValueError('unsupported provider')
    source = PROVIDERS[provider]
    path = Path(root) / CATALOG_DIRECTORY / source['catalog']
    raw = path.read_bytes()
    entry = json.loads(raw).get(model)
    if not isinstance(entry, dict) or entry.get('provider') != source['catalog_provider']:
        raise ValueError('model is not in the provider catalog')
    cost = entry.get('cost') if isinstance(entry.get('cost'), dict) else {}
    prices = {name: _price(cost.get(name)) for _, name in COUNTERS}
    if any(price is None for price in prices.values()):
        raise ValueError('catalog entry lacks a complete list price')
    return {'label': LABEL, 'provider': provider, 'model': model, 'basis': source['basis'],
            'catalog_file': (CATALOG_DIRECTORY / source['catalog']).as_posix(),
            'catalog_sha256': hashlib.sha256(raw).hexdigest(), 'catalog_provider': source['catalog_provider'],
            'unit': UNIT, 'prices': prices,
            # Counters are aggregated per trial, so a per-request long-context tier cannot be applied.
            'long_context_tier_in_catalog': 'long_context' in cost,
            'formula': 'sum(counter_tokens * price) / 1e6 over uncached input, cache read, cache write, output'}


def equivalent_spend(row, basis):
    """(usd, status): priced only when every token counter is a recorded number, else (None, missing)."""
    total = 0
    for counter, price_name in COUNTERS:
        value = row.get(counter)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0 or value != value:
            return None, 'missing_counters'
        total += value * basis['prices'][price_name]
    return round(total / 1_000_000, 10), 'priced'


def summarize_spend(rows):
    """Variant-level equivalent spend over **all attempted** trials, failures and timeouts included."""
    attempted = [row for row in rows if row.get('attempted', True)]
    successes = sum(bool(row['passed']) for row in attempted)
    values = [row.get('equivalent_spend_usd') for row in attempted]
    observed = [value for value in values if value is not None]
    complete = bool(attempted) and len(observed) == len(attempted)
    total = round(sum(observed), 10)
    status = 'undefined_zero_successes' if successes == 0 else ('complete' if complete else 'incomplete_missing_counters')
    return {'label': LABEL, 'total_usd': total if complete else None, 'observed_total_usd': total if observed else None,
            'trials_priced': len(observed), 'trials_unpriced': len(attempted) - len(observed), 'complete': complete,
            'per_verified_success_usd': round(total / successes, 10) if successes and complete else None,
            'per_verified_success_status': status}
