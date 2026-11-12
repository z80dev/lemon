class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['render_id'], 'tenant': raw['render_tenant'],
                'day': raw['render_day'], 'value': raw['render_value']}
