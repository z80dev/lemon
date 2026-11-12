from importlib import import_module

SOURCES = ['checkout', 'refund', 'shipment', 'return', 'signup', 'login', 'download', 'upload', 'render', 'query', 'backup', 'restore', 'scan', 'index', 'export', 'import']

def _service(source):
    if source not in SOURCES:
        raise ValueError('unknown source')
    return import_module(f'sources.{source}.service')


def ingest(source, ledger, rows):
    return _service(source).ingest(ledger, rows)


def preview(source, ledger, rows):
    return _service(source).preview(ledger, rows)
