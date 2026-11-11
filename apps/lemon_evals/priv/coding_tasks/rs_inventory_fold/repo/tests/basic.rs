use rs_inventory_fold::{fold, Event, Kind};

#[test]
fn receives_are_sorted_by_sku_and_preserve_last_id() {
    let result = fold(&[
        Event { id: 0, sku: "Z".into(), kind: Kind::Receive(3) },
        Event { id: 10, sku: "A".into(), kind: Kind::Receive(7) },
        Event { id: 12, sku: "Z".into(), kind: Kind::Receive(2) },
    ]).unwrap();
    assert_eq!(result.items["Z"].on_hand, 5);
    assert_eq!(result.items["A"].available(), 7);
    assert_eq!(result.last_id, Some(12));
    assert_eq!(result.items.keys().map(String::as_str).collect::<Vec<_>>(), vec!["A", "Z"]);
    assert!(fold(&[]).unwrap().items.is_empty());
}
