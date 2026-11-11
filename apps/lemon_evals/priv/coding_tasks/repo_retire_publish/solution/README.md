# Relay event service

A local tenant-aware event journal used by billing, fulfillment and collaboration.
Run `node --test tests/*.test.ts` or `node scripts/demo.ts` with Node 22.23.
No packages or network services are needed.

## Current integration

Use `bus.dispatch(request)` through the DispatchTarget interface. All feature
entry points return DispatchReceipt and propagate the caller context explicitly.

## Dispatch contract

`dispatch({tenantId,actorId,key,topic,payload})` returns `{id,accepted}`. On first
acceptance IDs are evt-1, evt-2, ... in insertion order; accepted is true. Repeated
(tenantId,topic,key) returns the first ID and accepted:false without appending or
changing the original payload. Different tenants or topics are independent.
DispatchTarget is the public interface containing dispatch only. Feature functions
must return the receipt directly, use context.tenantId/context.actorId and
context.requestId as key, and preserve the normalized payload below. Context strings
are propagated unchanged, not trimmed. Actor identity is never inferred.

All four request strings must be nonempty after trimming (`<field> must be nonempty`).
Topics contain at least two lowercase alphabetic dotted words
(`topic must be dotted lowercase words`). Payload must be a non-null, non-array
object (`payload must be an object`). Validation precedes deduplication. Events
and snapshots are mutation-isolated: later edits to input or returned snapshots
must not mutate journal state. snapshot returns DispatchRequest plus id; size
counts unique accepted requests. topicCounts counts events by topic; tenantEvents
filters by tenant while preserving order.

## Feature mappings

Every feature has signature `(bus, context, input)`. All string input fields are
trimmed and must be nonempty (`<field> must be nonempty`). Numeric input fields
must be positive integers (`<field> must be a positive integer`). `email` trims,
lowercases and requires @ (`email must contain @`). The expressions below also
specify case/slug normalization. Input errors must not record an event.

| Entry point | Topic | Input | Normalized payload |
| --- | --- | --- | --- |
| `releaseArticle` | `article.released` | `{ articleId: string; title: string }` | `{ articleId: text(input.articleId, 'articleId'), title: text(input.title, 'title') }` |
| `archiveDocument` | `document.archived` | `{ documentId: string; reason: string }` | `{ documentId: text(input.documentId, 'documentId'), reason: text(input.reason, 'reason') }` |
| `issueInvoice` | `invoice.issued` | `{ invoiceId: string; cents: number }` | `{ invoiceId: text(input.invoiceId, 'invoiceId'), cents: positive(input.cents, 'cents'), currency: 'USD' }` |
| `capturePayment` | `payment.captured` | `{ paymentId: string; cents: number }` | `{ paymentId: text(input.paymentId, 'paymentId'), cents: positive(input.cents, 'cents') }` |
| `requestRefund` | `refund.requested` | `{ paymentId: string; cents: number; reason: string }` | `{ paymentId: text(input.paymentId, 'paymentId'), cents: positive(input.cents, 'cents'), reason: text(input.reason, 'reason') }` |
| `packShipment` | `shipment.packed` | `{ shipmentId: string; tracking: string }` | `{ shipmentId: text(input.shipmentId, 'shipmentId'), tracking: text(input.tracking, 'tracking').toUpperCase() }` |
| `submitOrder` | `order.submitted` | `{ orderId: string; lines: number }` | `{ orderId: text(input.orderId, 'orderId'), lines: positive(input.lines, 'lines') }` |
| `reserveInventory` | `inventory.reserved` | `{ sku: string; quantity: number }` | `{ sku: text(input.sku, 'sku').toUpperCase(), quantity: positive(input.quantity, 'quantity') }` |
| `inviteMember` | `member.invited` | `{ email: string; role: string }` | `{ email: email(input.email), role: text(input.role, 'role').toLowerCase() }` |
| `revokeAccess` | `access.revoked` | `{ memberId: string; reason: string }` | `{ memberId: text(input.memberId, 'memberId'), reason: text(input.reason, 'reason') }` |
| `createProject` | `project.created` | `{ projectId: string; slug: string }` | `{ projectId: text(input.projectId, 'projectId'), slug: text(input.slug, 'slug').toLowerCase().replace(/\s+/g, '-') }` |
| `promoteDeployment` | `deployment.promoted` | `{ deploymentId: string; environment: string }` | `{ deploymentId: text(input.deploymentId, 'deploymentId'), environment: text(input.environment, 'environment').toLowerCase() }` |
| `openIncident` | `incident.opened` | `{ incidentId: string; severity: number }` | `{ incidentId: text(input.incidentId, 'incidentId'), severity: positive(input.severity, 'severity') }` |
| `addComment` | `comment.added` | `{ threadId: string; body: string }` | `{ threadId: text(input.threadId, 'threadId'), body: text(input.body, 'body') }` |
| `scheduleReport` | `report.scheduled` | `{ reportId: string; format: string }` | `{ reportId: text(input.reportId, 'reportId'), format: text(input.format, 'format').toLowerCase() }` |

A single context.requestId may be used for multiple different topics, but within
a topic it identifies one operation. CLI demonstrates billing and membership
against the same request context. It prints invoiceReceipt and inviteReceipt objects with acceptance status.
