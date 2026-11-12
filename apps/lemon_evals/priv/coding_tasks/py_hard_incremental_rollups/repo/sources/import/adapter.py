class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['import_id'], 'tenant': raw['import_tenant'],
                'day': raw['import_day'], 'value': raw['import_value']}
