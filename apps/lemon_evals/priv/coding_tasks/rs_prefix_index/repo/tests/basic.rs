use rs_prefix_index::{Index, Scope as S, Action as A};

#[test]
fn tenant_ties_global_depth_and_segment_boundaries() {
    let mut index = Index::new();
    index.set(S::Global, "/", A::Route("default".into())).unwrap();
    index.set(S::Global, "/api", A::Deny).unwrap();
    index.set(S::Tenant(7), "/api", A::Route("private".into())).unwrap();
    index.set(S::Global, "/api/public", A::Route("public".into())).unwrap();
    assert_eq!(index.lookup(7, "/api/x").unwrap().matched.unwrap().action, A::Route("private".into()));
    assert_eq!(index.lookup(7, "/api/public/x").unwrap().matched.unwrap().action, A::Route("public".into()));
    assert_eq!(index.lookup(8, "/api/x").unwrap().matched.unwrap().action, A::Deny);
    assert_eq!(index.lookup(7, "/apix").unwrap().matched.unwrap().prefix, "/");
}

#[test]
fn normalized_replacement_and_removal() {
    let mut index = Index::default();
    assert_eq!(index.set(S::Global, "//a/./b/", A::Deny).unwrap(), None);
    assert_eq!(index.set(S::Global, "/a/b", A::Route("".into())).unwrap(), Some(A::Deny));
    assert_eq!(index.len(), 1);
    assert_eq!(index.remove(S::Global, "/a//b/.").unwrap(), Some(A::Route("".into())));
    assert!(index.is_empty());
}
