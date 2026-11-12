class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['download_id'], 'tenant': raw['download_tenant'],
                'day': raw['download_day'], 'value': raw['download_value']}
