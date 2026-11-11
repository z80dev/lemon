# Warehouse Desk

An offline inventory API with injected actor and clock context. Run Node 22.23;
there are no dependencies or compilation steps. `node scripts/ci.ts` runs source
and route metadata checks. `node --test tests/*.test.ts` runs the visible tests.
`node scripts/demo.ts` exercises a stock reservation.

## CI and source conventions

Preserve scripts/check-contracts.ts and scripts/ci.ts byte-for-byte and retain
package.json's `ci: node scripts/ci.ts` command. Do not remove/disable/loosen tests.
Fix the implementation; do not bypass the checker, suppress issues or change its
input scope. All relative source imports include .ts. No console calls in src/:
mutations record structured audit events. No Date.now() in src/: context.clock()
is the only mutation timestamp source. Route descriptors are Object.freeze'd,
with unique lower-kebab names and unique method/path pairs; all paths start /v1/;
every POST route sets requiresActor:true. Scripts may write to stdout/stderr.
A clean CI exits zero and prints exactly `contracts: ok` plus a newline.

## Route table

The manifest exports exactly these eight descriptors, in the table order.

| Name | Method | Path | Actor | Successful body/status |
| --- | --- | --- | --- | --- |
| health | GET | /v1/health | no | {ok:true}, 200 |
| stock-list | GET | /v1/stock | no | {items:[stock]}, 200 |
| stock-add | POST | /v1/stock | yes | stock, 200 |
| stock-get | GET | /v1/stock/:sku | no | stock, 200 |
| reservation-create | POST | /v1/reservations | yes | reservation, 201 |
| reservation-cancel | POST | /v1/reservations/:reservationId/cancel | yes | reservation, 200 |
| reservation-fulfill | POST | /v1/reservations/:reservationId/fulfill | yes | reservation, 200 |
| report | GET | /v1/report | no | summary, 200 |

`createApp()` returns {services,handle(request,context)}; apps have independent
state. `createContext(actorId=null,clock=()=>0)` injects identity/time. A request
is {method,path,body?}; a response is {status,body}. Actor is required and nonblank
for all mutations, checked before handler input or state changes. Reads are public.
No query parsing or HTTP server is required. Unknown method/path gives missing /
route not found. Empty path parameters are validated by the handler.

## State, errors and validation

Stock is {sku,onHand,reserved,available}; available = onHand - reserved.
POST /v1/stock accepts {sku,quantity}, creating stock on first use and otherwise
adding units. sku input trims and uppercases; whitespace-only/non-string fails
invalid / sku must be nonempty. quantity must be a finite positive integer (no
strings, zero, negative or fractional values), otherwise invalid / quantity must
be a positive integer. GET stock list sorts by normalized sku. Unknown sku is
missing / sku not found. All validation happens before state changes or audit.

Reservations accept {reservationId,sku,quantity}. IDs trim and must be nonempty
strings, otherwise invalid / reservationId must be nonempty. Existing IDs always
fail conflict / reservationId already exists without altering stock. Unknown sku
fails missing / sku not found. Insufficient available stock fails conflict /
insufficient stock. Successful reservation increases reserved, never onHand.
Reservation is {reservationId,sku,quantity,status}, initially active. Cancel active
releases reserved once and sets cancelled; repeating cancel is a successful no-op
with no new audit. Cancel fulfilled fails conflict / reservation already fulfilled.
Fulfill active subtracts quantity from both onHand and reserved and sets fulfilled;
fulfilling cancelled/fulfilled fails conflict / reservation is not active. Unknown
reservation is missing / reservation not found. Failed operations never mutate
state or audit. No reservation deletion or ID reuse. Returned rows are snapshots.

Errors always have body {error:<code>,message:<message>} with invalid=400,
missing=404, conflict=409, unauthorized=401 (`actor required`). Unexpected errors
map to 500 / {error:"internal",message:"internal error"}. ApiError is public.
Summary is {skus,onHand,reserved,available,activeReservations}; numeric totals are
sums over stock, and activeReservations counts only active reservation records.

## Audit

services.audit.snapshot() returns mutation-isolated entries in operation order.
One entry per successful effective mutation, never reads/errors/repeated cancel:
{action,actorId,at,subject}. Actions are stock.added (subject normalized sku),
reservation.created, reservation.cancelled, reservation.fulfilled (subject normalized
reservationId). actorId is the unchanged context actor and at is context.clock().
