use rs_route_overlay::*;
#[test]
fn exact_overlay() {
    let mut t = RouteTable::new();
    t.apply_layer(&[Change::Set {prefix:"/api".into(),target:"blue".into()}]).unwrap();
    t.apply_layer(&[Change::Set {prefix:"/api".into(),target:"green".into()}]).unwrap();
    assert_eq!(t.resolve("/api").unwrap().unwrap().target,"green");
    assert!(t.pop_layer());
    assert_eq!(t.resolve("/api").unwrap().unwrap().target,"blue");
}
