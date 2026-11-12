class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['return_id'], 'tenant': raw['return_tenant'],
                'day': raw['return_day'], 'value': raw['return_value']}
