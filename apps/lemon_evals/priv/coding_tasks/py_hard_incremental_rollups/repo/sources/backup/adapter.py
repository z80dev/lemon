class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['backup_id'], 'tenant': raw['backup_tenant'],
                'day': raw['backup_day'], 'value': raw['backup_value']}
