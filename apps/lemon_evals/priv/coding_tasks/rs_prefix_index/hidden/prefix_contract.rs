use rs_prefix_index::{Index, Scope as S, Action as A, PathError as E, RuleMatch};
use std::collections::BTreeMap;

fn route(s: &str) -> A { A::Route(s.into()) }
fn check(index: &Index, tenant: u64, path: &str, expected: Option<(S, &str, A)>) {
    let result = index.lookup(tenant, path).unwrap();
    assert_eq!(result.matched, expected.map(|(scope, prefix, action)| RuleMatch { scope, prefix: prefix.into(), action }));
    let depth = path.split('/').filter(|s| !s.is_empty() && *s != ".").count();
    assert!(result.nodes_visited <= 2 * (depth + 2), "{} visits for {path}", result.nodes_visited);
    assert_eq!(result, index.lookup(tenant, path).unwrap(), "queries must be stable");
}

#[test]
fn scope_specificity_deny_and_deletion() {
    let mut index = Index::new();
    check(&index, 1, "/", None);
    assert_eq!(index.lookup(1, "/").unwrap().nodes_visited, 0);
    index.set(S::Global, "/", route("g-root")).unwrap();
    index.set(S::Tenant(1), "/", A::Deny).unwrap();
    index.set(S::Global, "/a", route("g-a")).unwrap();
    index.set(S::Tenant(1), "/a", A::Deny).unwrap();
    index.set(S::Global, "/a/b", route("g-b")).unwrap();
    index.set(S::Tenant(2), "/a/b/c", route("other")).unwrap();
    check(&index, 1, "/zzz", Some((S::Tenant(1), "/", A::Deny)));
    check(&index, 1, "/a/x", Some((S::Tenant(1), "/a", A::Deny)));
    check(&index, 1, "/a/b/c", Some((S::Global, "/a/b", route("g-b"))));
    check(&index, 2, "/a/b/c/d", Some((S::Tenant(2), "/a/b/c", route("other"))));
    assert_eq!(index.set(S::Tenant(1), "/a/b", A::Deny).unwrap(), None);
    check(&index, 1, "/a/b", Some((S::Tenant(1), "/a/b", A::Deny)));
    assert_eq!(index.remove(S::Tenant(1), "/a").unwrap(), Some(A::Deny));
    check(&index, 1, "/a/b/child", Some((S::Tenant(1), "/a/b", A::Deny)));
    assert_eq!(index.remove(S::Tenant(1), "/a/b").unwrap(), Some(A::Deny));
    check(&index, 1, "/a/b", Some((S::Global, "/a/b", route("g-b"))));
    index.remove(S::Global, "/a").unwrap();
    check(&index, 1, "/a/b", Some((S::Global, "/a/b", route("g-b"))));
    index.remove(S::Tenant(1), "/").unwrap();
    check(&index, 1, "/a/x", Some((S::Global, "/", route("g-root"))));
    assert_eq!(index.remove(S::Tenant(1), "/missing").unwrap(), None);
    assert_eq!(index.len(), 3);
}

#[test]
fn normalization_literals_and_error_atomicity() {
    let mut index = Index::new();
    index.set(S::Global, "////./", A::Deny).unwrap();
    for path in ["/雪/É", "/.../%2e%2e", "/a?b/#c", "/ spaced /x", "/Case/x"] {
        index.set(S::Tenant(5), path, route(path)).unwrap();
        check(&index, 5, &format!("{path}//./tail/"), Some((S::Tenant(5), path, route(path))));
    }
    check(&index, 5, "/case/x", Some((S::Global, "/", A::Deny)));
    check(&index, 5, "/雪/Éx", Some((S::Global, "/", A::Deny)));
    for (path, error) in [("", E::NotAbsolute), ("a", E::NotAbsolute), ("..", E::NotAbsolute),
        ("x\\", E::NotAbsolute), ("/a/../b", E::ParentSegment), ("/..", E::ParentSegment),
        ("/a\\b", E::InvalidCharacter), ("/a\0b", E::InvalidCharacter), ("/a\nb", E::InvalidCharacter),
        ("/a/../\u{85}", E::InvalidCharacter)] {
        let length = index.len();
        let before = index.lookup(5, "/雪/É").unwrap();
        assert_eq!(index.set(S::Global, path, route("bad")), Err(error.clone()));
        assert_eq!(index.remove(S::Global, path), Err(error.clone()));
        assert_eq!(index.lookup(5, path), Err(error));
        assert_eq!(index.len(), length);
        assert_eq!(index.lookup(5, "/雪/É").unwrap(), before);
    }
    assert_eq!(index.set(S::Global, "/./", route("")).unwrap(), Some(A::Deny));
    check(&index, 99, "//", Some((S::Global, "/", route(""))));
}

#[test]
fn wide_index_churn_has_path_bounded_work() {
    let mut index = Index::new();
    index.set(S::Global, "/", route("fallback")).unwrap();
    index.set(S::Tenant(3), "/api", A::Deny).unwrap();
    for n in 0..12000 {
        index.set(S::Global, &format!("/api/item{n}/detail"), route(&format!("g{n}"))).unwrap();
        index.set(S::Tenant(100 + n), "/api", route("unrelated")).unwrap();
    }
    for n in 0..240 {
        let item = n * 47;
        check(&index, 3, &format!("/api/item{item}/detail/tail"),
            Some((S::Global, &format!("/api/item{item}/detail"), route(&format!("g{item}")))));
        check(&index, 3, "/api/missing/tail", Some((S::Tenant(3), "/api", A::Deny)));
    }
    for n in 0..12000 {
        let path = format!("/api/item{n}/detail");
        if n % 3 == 0 {
            assert!(index.remove(S::Global, &path).unwrap().is_some());
        } else {
            assert!(index.set(S::Global, &path, A::Deny).unwrap().is_some());
        }
    }
    assert_eq!(index.len(), 20002);
    for n in 0..180 {
        let path = format!("/api/item{n}/detail");
        if n % 3 == 0 {
            check(&index, 3, &path, Some((S::Tenant(3), "/api", A::Deny)));
            index.set(S::Global, &path, route("reborn")).unwrap();
            check(&index, 3, &path, Some((S::Global, &path, route("reborn"))));
        } else {
            check(&index, 3, &path, Some((S::Global, &path, A::Deny)));
        }
    }
    check(&index, u64::MAX, "/unrelated", Some((S::Global, "/", route("fallback"))));
}

#[test]
fn deep_prefix_removal_keeps_descendants_and_reclaims_empty_scopes() {
    let mut index = Index::new();
    let mut paths = Vec::new();
    let mut path = String::new();
    for depth in 0..96 {
        path.push_str(&format!("/s{depth}"));
        paths.push(path.clone());
        index.set(S::Tenant(8), &path, route(&depth.to_string())).unwrap();
    }
    for depth in (0..96).step_by(2) { index.remove(S::Tenant(8), &paths[depth]).unwrap(); }
    check(&index, 8, &format!("{}/tail", paths[95]), Some((S::Tenant(8), &paths[95], route("95"))));
    for depth in (1..96).step_by(2) { index.remove(S::Tenant(8), &paths[depth]).unwrap(); }
    assert!(index.is_empty());
    assert_eq!(index.lookup(8, &path).unwrap().nodes_visited, 0);
    index.set(S::Tenant(8), &paths[20], A::Deny).unwrap();
    check(&index, 8, &paths[30], Some((S::Tenant(8), &paths[20], A::Deny)));
}

fn expected(model: &BTreeMap<(S, String), A>, tenant: u64, path: &str) -> Option<RuleMatch> {
    let mut best: Option<RuleMatch> = None;
    for ((scope, prefix), action) in model {
        if *scope != S::Global && *scope != S::Tenant(tenant) { continue; }
        if prefix != "/" && path != prefix && !path.starts_with(&format!("{prefix}/")) { continue; }
        if best.as_ref().map_or(true, |old| prefix.len() > old.prefix.len() ||
            (prefix.len() == old.prefix.len() && *scope == S::Tenant(tenant))) {
            best = Some(RuleMatch { scope: *scope, prefix: prefix.clone(), action: action.clone() });
        }
    }
    best
}

#[test]
fn deterministic_updates_match_a_simple_model() {
    let mut index = Index::new();
    let mut model = BTreeMap::new();
    let mut seed = 17u64;
    for step in 0..1800 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let tenant = (seed >> 10) % 7;
        let scope = if seed & 4 == 0 { S::Global } else { S::Tenant(tenant) };
        let path = match (seed >> 20) % 4 {
            0 => "/".to_owned(),
            1 => format!("/x{}", (seed >> 32) % 19),
            _ => format!("/x{}/y{}", (seed >> 32) % 19, (seed >> 40) % 11),
        };
        if seed & 3 == 0 {
            assert_eq!(index.remove(scope, &path).unwrap(), model.remove(&(scope, path.clone())));
        } else {
            let action = if seed & 8 == 0 { A::Deny } else { route(&format!("v{step}")) };
            assert_eq!(index.set(scope, &path, action.clone()).unwrap(), model.insert((scope, path.clone()), action));
        }
        assert_eq!(index.len(), model.len());
        let query = if path == "/" { "/tail".to_owned() } else { format!("{path}/tail") };
        let answer = index.lookup(tenant, &query).unwrap();
        assert_eq!(answer.matched, expected(&model, tenant, &query));
        let depth = query.split('/').filter(|s| !s.is_empty()).count();
        assert!(answer.nodes_visited <= 2 * (depth + 2));
    }
}
