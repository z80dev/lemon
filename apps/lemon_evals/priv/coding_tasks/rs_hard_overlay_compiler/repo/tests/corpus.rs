use rs_hard_overlay_compiler::service;
#[test]
fn documented_deployment_corpus() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("cases");
    let mut paths: Vec<_> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("schema"))
        .collect();
    paths.sort();
    for path in paths {
        let schema = std::fs::read_to_string(&path).unwrap();
        let layers = std::fs::read_to_string(path.with_extension("layers")).unwrap();
        let expected = std::fs::read_to_string(path.with_extension("expected")).unwrap();
        let actual = match service::render_text(&schema, &layers, "release", true) {
            Ok(text) => text,
            Err(error) => format!("ERROR {error}"),
        };
        assert_eq!(
            actual,
            expected.trim_end_matches('\n'),
            "{}",
            path.display()
        );
    }
}
