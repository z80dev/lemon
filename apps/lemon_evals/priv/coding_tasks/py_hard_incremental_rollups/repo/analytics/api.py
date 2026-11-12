from importlib import import_module

SOURCES = ['checkout', 'refund', 'shipment', 'return', 'signup', 'login', 'download', 'upload', 'render', 'query', 'backup', 'restore', 'scan', 'index', 'export', 'import']

def ingest(source, ledger, rows):
    if source not in SOURCES:
        raise ValueError('unknown source')
    return import_module(f'sources.{source}.service').ingest(ledger, rows)
