class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['scan_id'], 'tenant': raw['scan_tenant'],
                'day': raw['scan_day'], 'value': raw['scan_value']}
