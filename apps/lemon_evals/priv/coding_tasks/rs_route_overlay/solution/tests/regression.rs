use rs_route_overlay::*;
fn set(prefix:&str,target:&str)->Change {Change::Set{prefix:prefix.into(),target:target.into()}}
#[test]
fn tombstone_falls_back_and_bad_batch_rolls_back() {
    let mut table=RouteTable::new();
    table.apply_layer(&[set("/","root"),set("/a","specific")]).unwrap();
    table.apply_layer(&[Change::Remove{prefix:"/a/".into()}]).unwrap();
    assert_eq!(table.resolve("/a/b").unwrap().unwrap().target,"root");
    assert!(table.apply_layer(&[set("/good","new"),set("relative","bad")]).is_err());
    assert_eq!(table.depth(),2);
    assert_eq!(table.resolve("/good").unwrap().unwrap().target,"root");
    table.pop_layer();
    assert_eq!(table.resolve("/a/b").unwrap().unwrap().target,"specific");
}
