class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['checkout_id'], 'tenant': raw['checkout_tenant'],
                'day': raw['checkout_day'], 'value': raw['checkout_value']}
