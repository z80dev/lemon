class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['query_id'], 'tenant': raw['query_tenant'],
                'day': raw['query_day'], 'value': raw['query_value']}
