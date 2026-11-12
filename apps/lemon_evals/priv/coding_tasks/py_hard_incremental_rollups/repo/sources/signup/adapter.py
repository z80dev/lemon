class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['signup_id'], 'tenant': raw['signup_tenant'],
                'day': raw['signup_day'], 'value': raw['signup_value']}
