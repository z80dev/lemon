class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['restore_id'], 'tenant': raw['restore_tenant'],
                'day': raw['restore_day'], 'value': raw['restore_value']}
