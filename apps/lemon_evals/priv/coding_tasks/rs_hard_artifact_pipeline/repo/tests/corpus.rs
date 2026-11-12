use rs_hard_artifact_pipeline::service;
#[test]
fn documented_release_corpus() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("cases");
    let mut paths: Vec<_> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("pipeline"))
        .collect();
    paths.sort();
    for path in paths {
        let manifest = std::fs::read_to_string(&path).unwrap();
        let request = std::fs::read_to_string(path.with_extension("request")).unwrap();
        let expected = std::fs::read_to_string(path.with_extension("expected")).unwrap();
        let actual = match service::build_text(&manifest, &request) {
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
