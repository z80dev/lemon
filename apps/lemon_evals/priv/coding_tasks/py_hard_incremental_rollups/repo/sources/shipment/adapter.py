class Adapter:
    @staticmethod
    def decode(raw):
        return {'id': raw['shipment_id'], 'tenant': raw['shipment_tenant'],
                'day': raw['shipment_day'], 'value': raw['shipment_value']}
