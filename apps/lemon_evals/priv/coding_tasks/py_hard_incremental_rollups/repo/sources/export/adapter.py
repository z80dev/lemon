class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['export_id'], 'tenant': raw['export_tenant'],
                'day': raw['export_day'], 'value': raw['export_value']}
