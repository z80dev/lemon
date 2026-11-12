use arena_hidden_artifact_526::{
    Artifact, CacheEntry, Engine, EventSource, Manifest, Recipe, Request,
};
use rs_hard_artifact_pipeline as arena_hidden_artifact_526;
use std::collections::BTreeMap;
fn arena_hidden_artifact_manifest_526() -> Manifest {
    arena_hidden_artifact_526::parser::parse("z|join:-|b,a\na|source:aa aa|\nb|source:雪🦀β|\nc|replace:aa=>Q|a\nd|slice:1:3|b\ne|join:/|c,d\nunused|fail:not selected|\n").unwrap()
}
fn arena_hidden_artifact_request_526(ids: &[&str]) -> Request {
    Request {
        targets: ids.iter().map(|x| (*x).into()).collect(),
        overrides: BTreeMap::new(),
    }
}
fn arena_hidden_artifact_error_526(manifest: &str, request: &str, expected: &str) {
    assert_eq!(
        arena_hidden_artifact_526::service::build_text(manifest, request)
            .unwrap_err()
            .to_string(),
        expected
    );
}
#[test]
fn arena_hidden_artifact_planning_and_validation_526() {
    let m = arena_hidden_artifact_manifest_526();
    let r = arena_hidden_artifact_request_526(&["z", "e", "e"]);
    let p = arena_hidden_artifact_526::planning::plan(&m, &r).unwrap();
    assert_eq!(p.roots, ["e", "z"]);
    assert_eq!(p.order, ["a", "b", "c", "d", "e", "z"]);
    let mut reversed = m.clone();
    reversed.artifacts.reverse();
    assert_eq!(
        p,
        arena_hidden_artifact_526::planning::plan(&reversed, &r).unwrap()
    );
    let cases = [
        ("9bad|source:x|", "", "invalid-id:9bad"),
        ("a|source:x|\na|source:y|", "", "duplicate:a"),
        ("z|join:|missing\na|slice:2:1|z", "", "invalid-recipe:a"),
        ("a|source:x|\nx|join:|a,a", "", "duplicate-dependency:x->a"),
        (
            "a|source:x|\nx|join:|missing,missing",
            "",
            "missing-dependency:x->missing",
        ),
        ("a|source:x|\nx|replace:=>z|a", "", "invalid-recipe:x"),
        ("a|source:x|\nx|slice:0:1|", "", "invalid-recipe:x"),
        ("a|source:x|\nx|source:y|a", "", "invalid-recipe:x"),
        ("z|join:|z\na|join:|z", "target=missing", "cycle:a"),
        (
            "a|source:x|",
            "target=z\ntarget=b\noverride=absent=x",
            "unknown-target:b",
        ),
        ("a|source:x|", "override=z=x", "unknown-override:z"),
        ("a|join:|", "override=a=x", "not-source:a"),
        ("a|source:雪|\nx|slice:0:2|a", "target=x", "range:x"),
        (
            "a|fail:first|\nb|fail:second|",
            "target=b\ntarget=a",
            "execution:a:first",
        ),
    ];
    for (m, r, error) in cases {
        arena_hidden_artifact_error_526(m, r, error);
    }
    let mut e = Engine::new();
    let empty = e.build(&m, &Request::default()).unwrap();
    assert_eq!(empty.run, 1);
    assert!(empty.events.is_empty());
    assert!(empty.outputs.is_empty());
    assert_eq!(e.journal.len(), 1);
}
#[test]
fn arena_hidden_artifact_keys_and_cache_526() {
    let m = arena_hidden_artifact_manifest_526();
    let r = arena_hidden_artifact_request_526(&["e", "z"]);
    let mut e = Engine::new();
    let first = e.build(&m, &r).unwrap();
    assert_eq!(first.outputs["e"], "Q Q/🦀β");
    assert_eq!(first.outputs["z"], "雪🦀β-aa aa");
    assert!(first.events.iter().all(|x| x.source == EventSource::Built));
    assert_eq!(
        first.events[0].key,
        arena_hidden_artifact_526::digest::fields(&["a".into(), "source".into(), "aa aa".into()])
    );
    assert_eq!(
        arena_hidden_artifact_526::digest::hash(b""),
        "cbf29ce484222325"
    );
    assert_eq!(
        arena_hidden_artifact_526::digest::hash(b"hello"),
        "a430d84680aabd0b"
    );
    let mut r2 = r.clone();
    r2.overrides.insert("a".into(), "aa!".into());
    let second = e.build(&m, &r2).unwrap();
    assert_eq!(second.run, 2);
    for x in &second.events {
        assert_eq!(
            x.source,
            if ["b", "d"].contains(&x.id.as_str()) {
                EventSource::Cached
            } else {
                EventSource::Built
            }
        );
    }
    let third = e.build(&m, &r).unwrap();
    assert!(third.events.iter().all(|x| x.source == EventSource::Cached));
    assert_eq!(first.outputs, third.outputs);
    let mut reordered = m.clone();
    reordered.artifacts.reverse();
    assert!(e
        .build(&reordered, &r)
        .unwrap()
        .events
        .iter()
        .all(|x| x.source == EventSource::Cached));
    let key = first.events[0].key.clone();
    e.cache.get_mut(&key).unwrap().output = "corrupt".into();
    let repaired = e.build(&m, &r).unwrap();
    assert_eq!(repaired.events[0].source, EventSource::Built);
    assert_eq!(e.cache[&key].output, "aa aa");
    assert_eq!(
        e.cache[&key].digest,
        arena_hidden_artifact_526::digest::hash(b"aa aa")
    );
    let mut unrelated = r.clone();
    unrelated
        .overrides
        .insert("unused_source".into(), "new".into());
    let mut extended = m.clone();
    extended.artifacts.push(Artifact {
        id: "unused_source".into(),
        deps: vec![],
        recipe: Recipe::Source("old".into()),
    });
    assert!(e
        .build(&extended, &unrelated)
        .unwrap()
        .events
        .iter()
        .all(|x| x.source == EventSource::Cached));
    let mut swap = m.clone();
    swap.artifacts
        .iter_mut()
        .find(|x| x.id == "z")
        .unwrap()
        .deps
        .reverse();
    let swapped = e.build(&swap, &r).unwrap();
    assert_eq!(swapped.outputs["z"], "aa aa-雪🦀β");
    assert_eq!(swapped.events.last().unwrap().source, EventSource::Built);
}
#[test]
fn arena_hidden_artifact_atomic_failures_and_replay_526() {
    let m = arena_hidden_artifact_manifest_526();
    let r = arena_hidden_artifact_request_526(&["e"]);
    let mut e = Engine::new();
    e.build(&m, &r).unwrap();
    let mut failing = m.clone();
    failing.artifacts.push(Artifact {
        id: "zzfail".into(),
        deps: vec!["e".into()],
        recipe: Recipe::Fail("abort".into()),
    });
    let mut changed = arena_hidden_artifact_request_526(&["zzfail"]);
    changed.overrides.insert("a".into(), "new".into());
    let before = e.clone();
    assert!(e.build(&failing, &changed).is_err());
    assert_eq!(e, before);
    let valid = e.build(&m, &r).unwrap();
    assert_eq!(valid.run, 2);
    assert_eq!(
        arena_hidden_artifact_526::replay::replay(&e.journal).unwrap(),
        e
    );
    for mutation in 0..11 {
        let mut forged = e.journal.clone();
        match mutation {
            0 => forged[1].report.run += 1,
            1 => forged[1].report.roots.push("fake".into()),
            2 => forged[1].report.events.reverse(),
            3 => forged[1].report.events[0].key = "forged".into(),
            4 => forged[1].report.events[0].output = "forged".into(),
            5 => forged[1].report.events[0].source = EventSource::Built,
            6 => {
                forged[1].report.outputs.insert("e".into(), "forged".into());
            }
            7 => {
                forged[1]
                    .request
                    .overrides
                    .insert("a".into(), "different".into());
            }
            8 => forged[1].report.events[0].id = "fake".into(),
            9 => {
                forged[1].report.events.pop();
            }
            _ => forged[1].manifest.artifacts[0].deps.push("missing".into()),
        }
        let saved = e.clone();
        assert_eq!(e.restore(&forged).unwrap_err().to_string(), "journal:1");
        assert_eq!(e, saved);
    }
    let mut first_cached = e.journal.clone();
    first_cached[0].report.events[0].source = EventSource::Cached;
    assert_eq!(
        arena_hidden_artifact_526::replay::replay(&first_cached)
            .unwrap_err()
            .to_string(),
        "journal:0"
    );
    let mut receiver = Engine::new();
    receiver.cache.insert(
        "unrelated".into(),
        CacheEntry {
            output: "junk".into(),
            digest: "bad".into(),
        },
    );
    receiver.restore(&e.journal).unwrap();
    assert_eq!(receiver, e);
    receiver.restore(&[]).unwrap();
    assert_eq!(receiver, Engine::new());
}
#[test]
fn arena_hidden_artifact_text_adapters_and_cli_526() {
    let text = "# catalog\nz|join: :: |b,a\nb|source:β|\na|source: a=a |\n";
    let request = "# roots\ntarget=z\ntarget=z\noverride=b=雪=🦀\n";
    let result = arena_hidden_artifact_526::service::build_text(text, request).unwrap();
    assert!(result.ends_with("output|z|雪=🦀 ::  a=a "));
    assert_eq!(
        arena_hidden_artifact_526::service::plan_text(text, request).unwrap(),
        "a,b,z"
    );
    let batch = arena_hidden_artifact_526::batch::build_text(text, &[request, request]).unwrap();
    let pieces: Vec<_> = batch.split("\n--\n").collect();
    assert_eq!(pieces.len(), 2);
    assert!(pieces[1].starts_with("run=2\nroots=z\ncached|a|"));
    assert!(pieces[1].contains("\ncached|z|"));
    let mut engine = Engine::new();
    let m = arena_hidden_artifact_manifest_526();
    let report = engine
        .build(&m, &arena_hidden_artifact_request_526(&["e", "z"]))
        .unwrap();
    engine
        .build(&m, &arena_hidden_artifact_request_526(&["e", "z"]))
        .unwrap();
    let totals = arena_hidden_artifact_526::audit::totals(&engine);
    assert_eq!((totals.runs, totals.built, totals.cached), (2, 6, 6));
    assert_eq!(
        totals.bytes,
        report.events.iter().map(|x| x.output.len()).sum::<usize>() * 2
    );
    assert_eq!(
        arena_hidden_artifact_526::projection::outputs(&report, &["z".into(), "z".into()])
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        arena_hidden_artifact_526::projection::outputs(&report, &["a".into(), "no".into()])
            .unwrap_err()
            .to_string(),
        "not-output:a"
    );
    for (text, expected) in [
        ("\n# comment\nbad", "parse:3"),
        ("a|slice:+1:2|b", "parse:1"),
        ("a|slice:0: 2|b", "parse:1"),
        ("a|wat:x|", "parse:1"),
        ("a|source:x|extra|field", "parse:1"),
    ] {
        assert_eq!(
            arena_hidden_artifact_526::parser::parse(text)
                .unwrap_err()
                .to_string(),
            expected
        );
    }
    for text in [
        "target a",
        "override=a=x\noverride=a=y",
        "override=no_equals",
    ] {
        assert!(arena_hidden_artifact_526::request::parse(text).is_err());
    }
    let dir =
        std::env::temp_dir().join(format!("arena_hidden_artifact_526_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mp = dir.join("m");
    let rp = dir.join("r");
    std::fs::write(&mp, text).unwrap();
    std::fs::write(&rp, request).unwrap();
    let bin = env!("CARGO_BIN_EXE_rs_hard_artifact_pipeline");
    for command in ["build", "plan", "batch"] {
        let mut cmd = std::process::Command::new(bin);
        cmd.arg(command).arg(&mp).arg(&rp);
        if command == "batch" {
            cmd.arg(&rp);
        }
        let output = cmd.output().unwrap();
        assert!(output.status.success());
        let expected = match command {
            "build" => result.clone(),
            "plan" => "a,b,z".into(),
            _ => batch.clone(),
        };
        assert_eq!(String::from_utf8(output.stdout).unwrap(), expected + "\n");
    }
    std::fs::write(&rp, "target=absent").unwrap();
    let output = std::process::Command::new(bin)
        .arg("build")
        .arg(&mp)
        .arg(&rp)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(output.stderr, b"unknown-target:absent\n");
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn arena_hidden_artifact_many_interdependent_builds_526() {
    let mut nodes = vec![Artifact {
        id: "n00".into(),
        deps: vec![],
        recipe: Recipe::Source("x".into()),
    }];
    for i in 1..70 {
        nodes.push(Artifact {
            id: format!("n{i:02}"),
            deps: vec![format!("n{:02}", i - 1)],
            recipe: if i % 7 == 0 {
                Recipe::Replace {
                    from: "x".into(),
                    to: "xx".into(),
                }
            } else {
                Recipe::Join("".into())
            },
        });
    }
    let m = Manifest { artifacts: nodes };
    let mut e = Engine::new();
    for i in 0..8 {
        let mut r = arena_hidden_artifact_request_526(&["n69"]);
        r.overrides.insert("n00".into(), format!("x{i}"));
        let report = e.build(&m, &r).unwrap();
        assert_eq!(report.events.len(), 70);
        assert_eq!(report.outputs["n69"], format!("{}{}", "x".repeat(512), i));
        assert!(report
            .events
            .iter()
            .all(|event| event.source == EventSource::Built));
        assert!(e
            .build(&m, &r)
            .unwrap()
            .events
            .iter()
            .all(|event| event.source == EventSource::Cached));
    }
    assert_eq!(
        arena_hidden_artifact_526::replay::replay(&e.journal).unwrap(),
        e
    );
}
