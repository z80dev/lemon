import { createApp, createContext } from '../src/index.ts';
const app = createApp(); const context = createContext('warehouse-operator', () => 1700000000000);
app.handle({ method: 'POST', path: '/v1/stock', body: { sku: 'widget', quantity: 12 } }, context);
app.handle({ method: 'POST', path: '/v1/reservations', body: { reservationId: 'order-1', sku: 'widget', quantity: 3 } }, context);
console.log(JSON.stringify(app.handle({ method: 'GET', path: '/v1/report' }, context)));
