class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['refund_id'], 'tenant': raw['refund_tenant'],
                'day': raw['refund_day'], 'value': raw['refund_value']}
