class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['index_id'], 'tenant': raw['index_tenant'],
                'day': raw['index_day'], 'value': raw['index_value']}
