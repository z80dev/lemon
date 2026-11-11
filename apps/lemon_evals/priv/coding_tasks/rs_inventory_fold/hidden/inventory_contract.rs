use rs_inventory_fold::{fold, Event, Kind as K, ErrorKind as E, FoldError, Inventory};
fn ev(id: u64, sku: &str, kind: K) -> Event { Event { id, sku: sku.into(), kind } }
fn reserve(id: &str, quantity: u64) -> K { K::Reserve { reservation: id.into(), quantity } }
fn release(id: &str, quantity: u64) -> K { K::Release { reservation: id.into(), quantity } }
fn ship(id: &str, quantity: u64) -> K { K::Ship { reservation: id.into(), quantity } }
fn reject(inv: &mut Inventory, event: Event, kind: E) {
    let before = inv.clone();
    assert_eq!(inv.apply(&event), Err(FoldError { event_id: event.id, kind }));
    assert_eq!(*inv, before, "rejection must be atomic");
}

#[test]
fn reservation_lifecycle_and_corrections() {
    let mut i = fold(&[ev(0, "WIDGET", K::Receive(20)), ev(4, "WIDGET", reserve("order", 5)),
        ev(5, "WIDGET", reserve("order", 3)), ev(6, "WIDGET", reserve("other", 4))]).unwrap();
    assert_eq!(i.items["WIDGET"].available(), 8);
    assert_eq!(i.items["WIDGET"].reservations["order"], 8);
    i.apply(&ev(7, "WIDGET", release("order", 2))).unwrap();
    assert_eq!(i.items["WIDGET"].on_hand, 20);
    assert_eq!(i.items["WIDGET"].available(), 10);
    i.apply(&ev(8, "WIDGET", ship("order", 6))).unwrap();
    assert_eq!(i.items["WIDGET"].on_hand, 14);
    assert_eq!(i.items["WIDGET"].available(), 10);
    assert!(!i.items["WIDGET"].reservations.contains_key("order"));
    i.apply(&ev(9, "WIDGET", K::Correct(-10))).unwrap();
    assert_eq!(i.items["WIDGET"].available(), 0);
    reject(&mut i, ev(10, "WIDGET", K::Correct(-1)), E::InsufficientAvailable);
    reject(&mut i, ev(10, "WIDGET", reserve("x", 1)), E::InsufficientAvailable);
    i.apply(&ev(10, "WIDGET", release("other", 4))).unwrap();
    i.apply(&ev(11, "WIDGET", K::Correct(-4))).unwrap();
    assert_eq!(i.items["WIDGET"].on_hand, 0);
    assert!(i.items["WIDGET"].reservations.is_empty());
    i.apply(&ev(12, "NEW", K::Correct(8))).unwrap();
    i.apply(&ev(13, "NEW", reserve("other", 8))).unwrap();
    i.apply(&ev(14, "NEW", K::Receive(2))).unwrap();
    assert_eq!(i.items["NEW"].available(), 2);
}

#[test]
fn arithmetic_limits_do_not_wrap() {
    let mut i = fold(&[ev(1, "MAX", K::Receive(u64::MAX))]).unwrap();
    reject(&mut i, ev(2, "MAX", K::Receive(1)), E::Overflow);
    reject(&mut i, ev(2, "MAX", K::Correct(1)), E::Overflow);
    i.apply(&ev(2, "MAX", reserve("all", u64::MAX))).unwrap();
    reject(&mut i, ev(3, "MAX", reserve("all", 1)), E::InsufficientAvailable);
    reject(&mut i, ev(3, "MAX", K::Correct(i64::MIN)), E::InsufficientAvailable);
    i.apply(&ev(3, "MAX", release("all", u64::MAX))).unwrap();
    i.apply(&ev(4, "MAX", K::Correct(i64::MIN))).unwrap();
    assert_eq!(i.items["MAX"].on_hand, i64::MAX as u64);
    i.apply(&ev(u64::MAX, "MAX", K::Correct(-i64::MAX))).unwrap();
    assert_eq!(i.items["MAX"].on_hand, 0);
    reject(&mut i, ev(u64::MAX, "MAX", K::Receive(1)), E::NonIncreasingId);
}

#[test]
fn error_precedence_and_retry() {
    let mut i = Inventory::default();
    reject(&mut i, ev(0, "bad", reserve("!", 0)), E::InvalidSku);
    reject(&mut i, ev(0, "GOOD", reserve("!", 0)), E::InvalidReservation);
    for kind in [K::Receive(0), K::Correct(0), reserve("r", 0), release("r", 0), ship("r", 0)] {
        reject(&mut i, ev(0, "GOOD", kind), E::ZeroQuantity);
    }
    for kind in [reserve("r", 1), release("r", 1), ship("r", 1), K::Correct(-1)] {
        reject(&mut i, ev(0, "GOOD", kind), E::UnknownSku);
    }
    i.apply(&ev(0, "GOOD", K::Receive(5))).unwrap();
    reject(&mut i, ev(0, "bad", K::Receive(0)), E::NonIncreasingId);
    reject(&mut i, ev(1, "GOOD", release("r", 1)), E::UnknownReservation);
    reject(&mut i, ev(1, "GOOD", ship("r", 1)), E::UnknownReservation);
    i.apply(&ev(1, "GOOD", reserve("r", 3))).unwrap();
    reject(&mut i, ev(2, "GOOD", release("r", 4)), E::InsufficientReserved);
    reject(&mut i, ev(2, "GOOD", ship("r", 4)), E::InsufficientReserved);
    reject(&mut i, ev(2, "GOOD", reserve("s", 3)), E::InsufficientAvailable);
    i.apply(&ev(2, "GOOD", ship("r", 3))).unwrap();
    assert_eq!(i.items["GOOD"].on_hand, 2);
    assert_eq!(i.items["GOOD"].available(), 2);
}

#[test]
fn token_rules_and_independent_skus() {
    for bad in ["", "lower", "A B", "A/B", "É", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"] {
        reject(&mut Inventory::default(), ev(0, bad, K::Receive(1)), E::InvalidSku);
    }
    let valid = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123_-";
    let mut i = fold(&[ev(8, valid, K::Receive(9)), ev(9, "B", K::Receive(9))]).unwrap();
    for bad in ["", "a b", "a/b", "é", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] {
        reject(&mut i, ev(10, "B", reserve(bad, 1)), E::InvalidReservation);
    }
    i.apply(&ev(10, valid, reserve("aA_9-", 9))).unwrap();
    i.apply(&ev(11, "B", reserve("aA_9-", 2))).unwrap();
    i.apply(&ev(12, "B", reserve("Aa_9-", 1))).unwrap();
    assert_eq!(i.items[valid].available(), 0);
    assert_eq!(i.items["B"].available(), 6);
    assert_eq!(i.items["B"].reservations.len(), 2);
    let err = fold(&[ev(4, "A", K::Receive(1)), ev(3, "A", K::Receive(1)), ev(9, "A", K::Receive(1))]);
    assert_eq!(err, Err(FoldError { event_id: 3, kind: E::NonIncreasingId }));
}
