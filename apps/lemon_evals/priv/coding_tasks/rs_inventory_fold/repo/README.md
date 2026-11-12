# Ordered stock ledger

Implement the inventory fold in the existing modules. Quantities are integer units; there are no dependencies, timestamps, or floating point values.

## Public API

The root exports `Event { id: u64, sku: String, kind: Kind }`, `Kind`, `Stock { on_hand: u64, reservations: BTreeMap<String, u64> }`, `Inventory { last_id: Option<u64>, items: BTreeMap<String, Stock> }`, `FoldError { event_id: u64, kind: ErrorKind }`, and `fold(events: &[Event]) -> Result<Inventory, FoldError>`. Inventory and Stock implement Default; data/error types implement Debug, Clone, PartialEq, Eq. `Inventory::apply(&mut self, event: &Event) -> Result<(), FoldError>` is atomic on rejection. `Stock::available(&self) -> u64` is on_hand minus all reservations. Public fields are inspection surfaces: operations are required for default states and states produced by these APIs, not externally corrupted structures.

`Kind` variants:
* `Receive(u64)` adds physical stock, creating a SKU if needed.
* `Reserve { reservation: String, quantity: u64 }` takes available stock into that reservation. Reusing an ID accumulates its reserved quantity.
* `Release { reservation: String, quantity: u64 }` releases only that reservation's units; physical stock stays unchanged.
* `Ship { reservation: String, quantity: u64 }` consumes that reservation's units and the same physical units. Available stock stays unchanged.
* `Correct(i64)` adjusts physical stock by a signed delta without changing reservations. Positive corrections may create a SKU; negative corrections may consume only available stock. Handle i64::MIN without signed overflow.

Reservations are scoped by SKU. Remove a reservation when its quantity reaches zero. Keep SKU entries even at zero stock. Returned maps have deterministic sorted order. fold applies the input in its given order, never sorts, and returns the complete Inventory or the first error. Empty input returns Default.

## Validation and errors

IDs must be strictly increasing, not necessarily consecutive; the first ID may be 0 and u64::MAX is valid. Every rejected event leaves the entire inventory, including last_id, unchanged; a corrected event may retry its ID. Set last_id only on success.

SKU: 1..=32 ASCII uppercase letters/digits/underscore/hyphen. Reservation ID: 1..=32 ASCII letters/digits/underscore/hyphen, case-sensitive. Do not trim either. Quantities and corrections must be nonzero. All arithmetic is checked, never wrapping/saturating.

`ErrorKind` is exactly `NonIncreasingId`, `InvalidSku`, `InvalidReservation`, `ZeroQuantity`, `UnknownSku`, `UnknownReservation`, `InsufficientAvailable`, `InsufficientReserved`, `Overflow`. FoldError carries the rejected event's id. Validation precedence is ID, SKU, reservation ID (where applicable), zero quantity, then existence, then arithmetic/availability. A missing SKU on Reserve/Release/Ship or negative Correct is UnknownSku; positive Receive/Correct can create one. On Release/Ship, a missing reservation is UnknownReservation, and a quantity larger than that reservation is InsufficientReserved. Reserve larger than available or negative correction larger than available is InsufficientAvailable. Physical addition beyond u64::MAX is Overflow. Receive never alters reservations. Errors must not create empty SKU entries or consume IDs.

Use `cargo test --offline`. Keep parsing/validation rules and state transitions in their existing separate modules.
