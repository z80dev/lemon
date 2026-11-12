import { EventBus, context, issueInvoice, inviteMember, topicCounts } from '../src/index.ts';
const bus = new EventBus();
const actor = context('clinic', 'operator-1', 'request-1');
const invoiceId = issueInvoice(bus, actor, { invoiceId: 'inv-1', cents: 2500 });
const inviteId = inviteMember(bus, actor, { email: 'A@Example.test', role: 'EDITOR' });
console.log(JSON.stringify({ invoiceId, inviteId, counts: topicCounts(bus.snapshot()) }));
