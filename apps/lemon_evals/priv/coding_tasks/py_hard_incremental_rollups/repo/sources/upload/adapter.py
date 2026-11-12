class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['upload_id'], 'tenant': raw['upload_tenant'],
                'day': raw['upload_day'], 'value': raw['upload_value']}
