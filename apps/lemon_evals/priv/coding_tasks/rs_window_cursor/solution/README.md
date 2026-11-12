# Shipment batch cursor

`BatchCursor::new(&items, size)` splits a borrowed shipment slice into consecutive batches.
The iterator exposes `Batch { offset, items }`, where offset is an index into the original slice.
It implements `Iterator`, `ExactSizeIterator` and `FusedIterator`. Zero batch size is invalid,
even with no items. All other sizes are valid, including `usize::MAX`. The final batch may be
short; no batch is empty. `len()` and both bounds of `size_hint()` equal remaining batch count.
Batches borrow the original slice without requiring elements to implement Clone.

Run `cargo test --offline`.

The cursor emits the final short batch and computes its end from remaining length, avoiding overflow.
