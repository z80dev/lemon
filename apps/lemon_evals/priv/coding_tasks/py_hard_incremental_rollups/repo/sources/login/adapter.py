class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['login_id'], 'tenant': raw['login_tenant'],
                'day': raw['login_day'], 'value': raw['login_value']}
