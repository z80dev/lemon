use rs_route_overlay::*;
fn set(p:&str,t:&str)->Change { Change::Set {prefix:p.into(),target:t.into()} }
fn remove(p:&str)->Change { Change::Remove {prefix:p.into()} }
fn expected(p:&str,t:&str,r:&str,l:usize)->Option<Resolved> {Some(Resolved{prefix:p.into(),target:t.into(),remainder:r.into(),layer:l})}
#[test]
fn canonical_prefixes_and_overlay_keys() {
    let mut t = RouteTable::new();
    t.apply_layer(&[set("/","root"),set("//api/./v1/","old"),set("/api","api")]).unwrap();
    t.apply_layer(&[set("/","newroot"),set("/api","newapi")]).unwrap();
    assert_eq!(t.resolve("/api//v1/./users/").unwrap(), expected("/api/v1","old","users",0));
    assert_eq!(t.resolve("/apix").unwrap(),expected("/","newroot","apix",1));
    assert_eq!(t.resolve("/api").unwrap(),expected("/api","newapi","",1));
    t.apply_layer(&[remove("/api/v1"),remove("/api")]).unwrap();
    assert_eq!(t.resolve("/api/v1/users").unwrap(),expected("/","newroot","api/v1/users",1));
    assert!(t.pop_layer());
    assert_eq!(t.resolve("/api/v1").unwrap(),expected("/api/v1","old","",0));
    t.apply_layer(&[set("/x/","first"),remove("//x"),set("/./x","last")]).unwrap();
    assert_eq!(t.resolve("/x/z").unwrap(),expected("/x","last","z",2));
    assert_eq!(t.resolve("///./").unwrap(),expected("/","newroot","",1));
}
#[test]
fn validation_is_atomic_ordered_and_utf8_is_literal() {
    let mut t = RouteTable::new();
    for bad in ["", "relative", "/x/../y", "/a?b", "/a#b", "/a\0b"] {
        assert_eq!(t.resolve(bad),Err(RouteError::InvalidPath(bad.into())));
        assert_eq!(t.apply_layer(&[set("/valid","v"),set(bad,"x")]),Err(RouteError::InvalidPath(bad.into())));
        assert_eq!(t.depth(),0);
    }
    assert_eq!(t.apply_layer(&[set("/ok","yes"),set("/no","")]),Err(RouteError::EmptyTarget{index:1}));
    assert_eq!(t.apply_layer(&[set("bad","")]),Err(RouteError::InvalidPath("bad".into())));
    assert_eq!(t.depth(),0);
    t.apply_layer(&[]).unwrap();
    t.apply_layer(&[set("/café/a b\\c"," "),set("/café/a b\\c/child","leaf")]).unwrap();
    assert_eq!(t.resolve("/café/a b\\c/child/z").unwrap(),expected("/café/a b\\c/child","leaf","z",1));
    assert_eq!(t.resolve("/Café/a b\\c").unwrap(),None);
    assert_eq!(t.depth(),2);
    assert!(t.pop_layer()); assert!(t.pop_layer()); assert!(!t.pop_layer());
    assert_eq!(t.resolve("/").unwrap(),None);
}
