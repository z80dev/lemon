use arena_hidden_overlay_526::{
    Compiled, Constraint, Kind, Layer, Op, Origin, Rule, Schema, Value,
};
use rs_hard_overlay_compiler as arena_hidden_overlay_526;
fn arena_hidden_overlay_error_526(schema: &str, layers: &str, target: &str, expected: &str) {
    assert_eq!(
        arena_hidden_overlay_526::service::compile_text(schema, layers, target)
            .unwrap_err()
            .to_string(),
        expected
    );
}
fn arena_hidden_overlay_schema_526() -> &'static str {
    "app.name|nonempty|required|public\napp.port|int:1:65535|required|public\napp.tags|list:1:8|required|public\napp.url|text|required|public\nauth.token|text|optional|secret\nauth.header|text|optional|secret\ncache.ttl|int:0:3600|optional|public\ncache.note|text|optional|public\ncachex|text|optional|public\n!requires|auth.header|auth.token\n"
}
fn arena_hidden_overlay_layers_526() -> &'static str {
    "[base]\nset|app.name|old\nset|app.port|80\nlist|app.tags|a,a,b\nset|app.url|${app.name}:${app.port}\nset|auth.token|initial\nset|auth.header|Bearer ${auth.token}\nset|cache.ttl|30\nset|cache.note|old\nset|cachex|keep\n[left]\nparents=base\nappend|app.tags|b,left\nset|app.port|00443\n[right]\nparents=base\nappend|app.tags|right,b\ndelete|cache\nset|auth.token|rotated\n[release]\nparents=left,right\nremove|app.tags|b\nappend|app.tags|${app.name},new,left\nset|app.name|new\nset|cache.ttl|60\nappend|app.tags|\n"
}
#[test]
fn arena_hidden_overlay_diamond_tombstone_provenance_526() {
    let (schema, compiled) = arena_hidden_overlay_526::service::compile_text(
        arena_hidden_overlay_schema_526(),
        arena_hidden_overlay_layers_526(),
        "release",
    )
    .unwrap();
    assert_eq!(compiled.layers, ["base", "left", "right", "release"]);
    assert_eq!(
        compiled.values["app.tags"].value,
        Value::List(vec![
            "a".into(),
            "left".into(),
            "right".into(),
            "new".into()
        ])
    );
    let tags = &compiled.values["app.tags"];
    assert_eq!(
        tags.origin,
        Origin {
            layer: "release".into(),
            operation: 4
        }
    );
    let origins: Vec<_> = tags
        .contributors
        .iter()
        .map(|x| (x.layer.as_str(), x.operation))
        .collect();
    assert_eq!(
        origins,
        [
            ("base", 2),
            ("left", 0),
            ("right", 0),
            ("release", 0),
            ("release", 1),
            ("release", 4)
        ]
    );
    assert_eq!(tags.references, ["app.name"]);
    assert_eq!(
        compiled.values["app.url"].value,
        Value::Text("new:00443".into())
    );
    assert_eq!(compiled.values["app.port"].value, Value::Integer(443));
    assert_eq!(
        compiled.values["auth.header"].value,
        Value::Text("Bearer rotated".into())
    );
    assert_eq!(compiled.values["cache.ttl"].value, Value::Integer(60));
    assert!(!compiled.values.contains_key("cache.note"));
    assert_eq!(compiled.values["cachex"].value, Value::Text("keep".into()));
    assert_eq!(
        compiled.tombstones["cache"],
        Origin {
            layer: "right".into(),
            operation: 1
        }
    );
    let redacted = arena_hidden_overlay_526::render::compiled(&compiled, &schema, true);
    assert!(!redacted.contains("rotated"));
    assert!(redacted.contains("value|auth.header|text|[REDACTED]|base:5|refs=auth.token"));
    assert!(
        arena_hidden_overlay_526::render::compiled(&compiled, &schema, false)
            .contains("Bearer rotated")
    );
    assert_eq!(arena_hidden_overlay_526::explain::path(&compiled, "app.tags").unwrap(), "origin=release:4;contributors=base:2,left:0,right:0,release:0,release:1,release:4;references=app.name");
    assert_eq!(
        arena_hidden_overlay_526::explain::path(&compiled, "cache.note")
            .unwrap_err()
            .to_string(),
        "not-found:cache.note"
    );
    let reversed =
        arena_hidden_overlay_layers_526().replace("parents=left,right", "parents=right,left");
    let (_, other) = arena_hidden_overlay_526::service::compile_text(
        arena_hidden_overlay_schema_526(),
        &reversed,
        "release",
    )
    .unwrap();
    assert_eq!(other.layers, ["base", "right", "left", "release"]);
    assert_eq!(
        other.values["app.tags"].value,
        Value::List(vec![
            "a".into(),
            "right".into(),
            "left".into(),
            "new".into()
        ])
    );
    let mut layers =
        arena_hidden_overlay_526::layer_parser::parse(arena_hidden_overlay_layers_526()).unwrap();
    layers.reverse();
    assert_eq!(
        arena_hidden_overlay_526::compile(&schema, &layers, "release").unwrap(),
        compiled
    );
}
#[test]
fn arena_hidden_overlay_interpolation_contract_526() {
    let schema = "a|text|optional|public\nb|text|optional|public\nc|text|optional|public\nd|list:0:9|optional|public\ns|text|optional|secret\nt|text|optional|secret\n";
    let layers = "[release]\nset|a|${b}/${c}/$${missing}/$$/$x/雪\nset|b|B${c}\nset|c|🦀\nlist|d|${b},B🦀,${c},$${c},${c}\nset|s|${t}:${b}\nset|t|secret\n";
    let (_, compiled) =
        arena_hidden_overlay_526::service::compile_text(schema, layers, "release").unwrap();
    assert_eq!(
        compiled.values["a"].value,
        Value::Text("B🦀/🦀/${missing}/$/$x/雪".into())
    );
    assert_eq!(compiled.values["a"].references, ["b", "c"]);
    assert_eq!(
        compiled.values["d"].value,
        Value::List(vec!["B🦀".into(), "🦀".into(), "${c}".into()])
    );
    assert_eq!(compiled.values["s"].references, ["b", "c", "t"]);
    for (layers, error) in [
        ("[release]\nset|a|${absent}", "reference:a->absent"),
        ("[release]\nset|a|${}", "reference:a->"),
        ("[release]\nset|a|${bad name}", "reference:a->bad name"),
        ("[release]\nset|a|${b", "interpolation:a"),
        ("[release]\nset|a|${d}\nlist|d|x", "reference-type:a->d"),
        ("[release]\nset|a|${b}\nset|b|${a}", "interpolation-cycle:a"),
        (
            "[release]\nset|a|${s}\nset|s|${missing}",
            "secret-flow:a->s",
        ),
        (
            "[release]\nset|a|${b}\nset|b|${s}\nset|s|secret",
            "secret-flow:b->s",
        ),
        ("[release]\nset|b|x\nset|a|${b}\ndelete|b", "reference:a->b"),
    ] {
        arena_hidden_overlay_error_526(schema, layers, "release", error);
    }
    let (_, escaped) = arena_hidden_overlay_526::service::compile_text(
        schema,
        "[release]\nset|a|${b}\nset|b|$${c}",
        "release",
    )
    .unwrap();
    assert_eq!(escaped.values["a"].value, Value::Text("${c}".into()));
    assert_eq!(escaped.values["a"].references, ["b"]);
}
#[test]
fn arena_hidden_overlay_merge_audit_and_resurrection_526() {
    let schema = "net|text|optional|public\nnet.host|text|optional|public\nnet.tags|list:0:8|optional|public\nnetwork|text|optional|public\n";
    let layers = "[release]\nset|net|root\nset|net.host|old\nlist|net.tags|a,b,a\nset|network|untouched\ndelete|net.host\ndelete|net\nappend|net.tags|x,x,y\nremove|net.tags|absent\nset|net.host|new\ndelete|net.host\nset|net.host|final\n";
    let (_, c) =
        arena_hidden_overlay_526::service::compile_text(schema, layers, "release").unwrap();
    assert_eq!(c.tombstones.len(), 2);
    assert_eq!(c.tombstones["net"].operation, 5);
    assert_eq!(c.tombstones["net.host"].operation, 9);
    assert!(!c.values.contains_key("net"));
    assert_eq!(c.values["net.host"].value, Value::Text("final".into()));
    assert_eq!(
        c.values["net.host"].contributors,
        [Origin {
            layer: "release".into(),
            operation: 10
        }]
    );
    assert_eq!(
        c.values["net.tags"].value,
        Value::List(vec!["x".into(), "y".into()])
    );
    assert_eq!(c.values["net.tags"].contributors.len(), 2);
    assert_eq!(c.values["net.tags"].origin.operation, 7);
    assert_eq!(c.values["network"].value, Value::Text("untouched".into()));
    arena_hidden_overlay_error_526(
        schema,
        "[release]\nremove|net.tags|x",
        "release",
        "missing-value:net.tags",
    );
    arena_hidden_overlay_error_526(
        schema,
        "[release]\nappend|net.tags|x\ndelete|net\nremove|net.tags|x",
        "release",
        "missing-value:net.tags",
    );
}
#[test]
fn arena_hidden_overlay_type_and_constraints_526() {
    for (kind, value, error) in [
        ("int:-3:3", "+1", "type:a"),
        ("int:-3:3", " 1", "type:a"),
        ("int:-3:3", "1 ", "type:a"),
        ("int:-3:3", "-", "type:a"),
        ("int:-3:3", "4", "type:a"),
        ("int:-3:3", "-4", "type:a"),
        ("int:-3:3", "9223372036854775808", "type:a"),
        ("bool", "True", "type:a"),
        ("bool", "1", "type:a"),
        ("nonempty", "", "type:a"),
    ] {
        arena_hidden_overlay_error_526(
            &format!("a|{kind}|optional|public"),
            &format!("[release]\nset|a|{value}"),
            "release",
            error,
        );
    }
    for (kind, input, expected) in [
        (
            Kind::Integer {
                min: i64::MIN,
                max: i64::MAX,
            },
            "-9223372036854775808",
            Value::Integer(i64::MIN),
        ),
        (Kind::Integer { min: -3, max: 3 }, "-000", Value::Integer(0)),
        (Kind::Text { nonempty: true }, " ", Value::Text(" ".into())),
        (Kind::Boolean, "false", Value::Boolean(false)),
    ] {
        let rule = Rule {
            path: "a".into(),
            kind,
            required: false,
            secret: false,
        };
        assert_eq!(
            arena_hidden_overlay_526::typing::convert(
                &rule,
                &arena_hidden_overlay_526::merge::RawValue::Scalar(input.into())
            )
            .unwrap(),
            expected
        );
    }
    arena_hidden_overlay_error_526(
        "a|list:2:4|optional|public",
        "[release]\nlist|a|x,x",
        "release",
        "type:a",
    );
    arena_hidden_overlay_error_526(
        "a|list:0:1|optional|public",
        "[release]\nlist|a|x,y",
        "release",
        "type:a",
    );
    arena_hidden_overlay_error_526(
        "a|bool|optional|public\nb|text|optional|public\n!requires|a|b",
        "[release]\nset|a|false",
        "release",
        "requires:a->b",
    );
    arena_hidden_overlay_error_526(
        "a|text|optional|public\nb|text|optional|public\n!exclusive|b,a",
        "[release]\nset|a|\nset|b|",
        "release",
        "exclusive:a,b",
    );
    arena_hidden_overlay_error_526(
        "z|text|required|public\na|text|required|public",
        "[release]",
        "release",
        "required:a",
    );
    arena_hidden_overlay_error_526(
        "a|text|required|public\nb|text|optional|public",
        "[release]\nset|b|${missing}",
        "release",
        "required:a",
    );
}
#[test]
fn arena_hidden_overlay_global_validation_precedence_526() {
    let s = "a|text|optional|public\nb|list:0:5|optional|public";
    for (schema, layers, target, error) in [
        (
            "A|text|optional|public",
            "[release]",
            "no",
            "invalid-path:A",
        ),
        (
            "a|text|optional|public\na|bool|optional|public",
            "[release]",
            "no",
            "duplicate-rule:a",
        ),
        (
            "a|int:2:1|optional|public",
            "[release]",
            "no",
            "invalid-rule:a",
        ),
        (
            "a|list:2:1|optional|public",
            "[release]",
            "no",
            "invalid-rule:a",
        ),
        (
            "a|text|optional|public\n!requires|a|unknown",
            "[release]",
            "no",
            "invalid-constraint:0",
        ),
        (
            "a|text|optional|public\n!exclusive|a,a",
            "[release]",
            "no",
            "invalid-constraint:0",
        ),
        (s, "[Bad]", "no", "invalid-layer:Bad"),
        (s, "[release]\n[release]", "no", "duplicate-layer:release"),
        (
            s,
            "[release]\nparents=absent",
            "no",
            "missing-parent:release->absent",
        ),
        (
            s,
            "[base]\n[release]\nparents=base,base",
            "no",
            "duplicate-parent:release->base",
        ),
        (
            s,
            "[release]\n[x]\nparents=x\n[a]\nparents=x",
            "release",
            "cycle:a",
        ),
        (
            s,
            "[release]\n[unused]\nset|bad.path|x",
            "release",
            "unknown-path:bad.path",
        ),
        (s, "[release]\nset|a..b|x", "release", "invalid-path:a..b"),
        (s, "[release]\nset|b|x", "release", "operation-type:b"),
        (s, "[release]\nlist|a|x", "release", "operation-type:a"),
        (s, "[release]\nappend|a|x", "release", "operation-type:a"),
        (s, "[release]\nremove|a|x", "release", "operation-type:a"),
        (
            s,
            "[release]\ndelete|absent",
            "release",
            "unknown-path:absent",
        ),
        (s, "[release]\nset|a|x", "no", "unknown-layer:no"),
    ] {
        arena_hidden_overlay_error_526(schema, layers, target, error);
    }
    let schema = Schema {
        rules: vec![Rule {
            path: "a".into(),
            kind: Kind::Text { nonempty: false },
            required: false,
            secret: false,
        }],
        constraints: vec![Constraint::Exclusive(vec!["a".into()])],
    };
    assert_eq!(
        arena_hidden_overlay_526::compile(&schema, &[], "x")
            .unwrap_err()
            .to_string(),
        "invalid-constraint:0"
    );
}
#[test]
fn arena_hidden_overlay_parsers_526() {
    for (text, error) in [
        ("# comment\n\na|int:+1:2|optional|public", "schema-parse:3"),
        ("a|list:-1:2|optional|public", "schema-parse:1"),
        ("a|int:1:2|maybe|public", "schema-parse:1"),
        ("a|text|optional|hidden", "schema-parse:1"),
        ("!unknown|a|b", "schema-parse:1"),
        ("a|wat|optional|public", "schema-parse:1"),
    ] {
        assert_eq!(
            arena_hidden_overlay_526::schema_parser::parse(text)
                .unwrap_err()
                .to_string(),
            error
        );
    }
    for (text, error) in [
        ("# comment\n\nset|a|x", "layer-parse:3"),
        ("[release]\nparents=\nparents=", "layer-parse:3"),
        ("[release]\nset|a|x\nparents=", "layer-parse:3"),
        ("[release]\ndelete|a|x", "layer-parse:2"),
        ("[release]\nwat|a|x", "layer-parse:2"),
    ] {
        assert_eq!(
            arena_hidden_overlay_526::layer_parser::parse(text)
                .unwrap_err()
                .to_string(),
            error
        );
    }
    let l = arena_hidden_overlay_526::layer_parser::parse("[release]\nset|a| x=y \nlist|b|a,, b\n")
        .unwrap();
    assert_eq!(
        l[0].operations[0],
        Op::Set {
            path: "a".into(),
            value: " x=y ".into()
        }
    );
    assert_eq!(
        l[0].operations[1],
        Op::SetList {
            path: "b".into(),
            values: vec!["a".into(), "".into(), " b".into()]
        }
    );
    let (schema, _) = arena_hidden_overlay_526::service::compile_text(
        "a|text|optional|public",
        "[release]",
        "release",
    )
    .unwrap();
    assert_eq!(schema.rules.len(), 1);
    assert_eq!(
        arena_hidden_overlay_526::batch::compile_text("bad", "bad", &[], true)
            .unwrap_err()
            .to_string(),
        "schema-parse:1"
    );
    assert_eq!(
        arena_hidden_overlay_526::batch::compile_text(
            "a|text|optional|public",
            "[release]",
            &[],
            true
        )
        .unwrap(),
        ""
    );
}
#[test]
fn arena_hidden_overlay_batch_diff_and_cli_526() {
    let schema = "a|text|optional|public\nb|text|optional|secret\nc|bool|optional|public";
    let layers = "[base]\nset|a|old\nset|b|secret\n[left]\nparents=base\nset|a|new\nset|c|false\n[right]\nparents=base\ndelete|a\nset|b|secret\n";
    let (s, base) =
        arena_hidden_overlay_526::service::compile_text(schema, layers, "base").unwrap();
    let (_, left) =
        arena_hidden_overlay_526::service::compile_text(schema, layers, "left").unwrap();
    let (_, right) =
        arena_hidden_overlay_526::service::compile_text(schema, layers, "right").unwrap();
    let diff = arena_hidden_overlay_526::diff::between(&base, &left);
    assert_eq!(diff.len(), 2);
    assert_eq!(diff[0].path, "a");
    assert_eq!(diff[0].before, Some(Value::Text("old".into())));
    assert_eq!(diff[0].after, Some(Value::Text("new".into())));
    assert_eq!(diff[1].path, "c");
    assert_eq!(diff[1].before, None);
    assert_eq!(diff[1].after, Some(Value::Boolean(false)));
    let removed = arena_hidden_overlay_526::diff::between(&base, &right);
    assert_eq!(removed.len(), 1);
    assert_eq!(removed[0].path, "a");
    assert_eq!(removed[0].after, None);
    assert!(
        arena_hidden_overlay_526::diff::between(&Compiled::default(), &Compiled::default())
            .is_empty()
    );
    let batch = arena_hidden_overlay_526::batch::compile_text(
        schema,
        layers,
        &["left", "right", "left"],
        true,
    )
    .unwrap();
    let pieces: Vec<_> = batch.split("\n--\n").collect();
    assert_eq!(pieces.len(), 3);
    assert_eq!(pieces[0], pieces[2]);
    assert_eq!(
        pieces[0],
        arena_hidden_overlay_526::render::compiled(&left, &s, true)
    );
    assert_eq!(
        pieces[1],
        arena_hidden_overlay_526::render::compiled(&right, &s, true)
    );
    let dir = std::env::temp_dir().join(format!("arena_hidden_overlay_526_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sp = dir.join("s");
    let lp = dir.join("l");
    std::fs::write(&sp, schema).unwrap();
    std::fs::write(&lp, layers).unwrap();
    let bin = env!("CARGO_BIN_EXE_rs_hard_overlay_compiler");
    for reveal in [false, true] {
        let mut cmd = std::process::Command::new(bin);
        cmd.arg("compile").arg(&sp).arg(&lp).arg("left");
        if reveal {
            cmd.arg("--reveal");
        }
        let output = cmd.output().unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8(output.stdout).unwrap(),
            arena_hidden_overlay_526::render::compiled(&left, &s, !reveal) + "\n"
        );
    }
    let output = std::process::Command::new(bin)
        .arg("explain")
        .arg(&sp)
        .arg(&lp)
        .args(["left", "b"])
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(
        output.stdout,
        b"origin=base:1;contributors=base:1;references=\n"
    );
    let output = std::process::Command::new(bin)
        .arg("batch")
        .arg(&sp)
        .arg(&lp)
        .args(["left", "right", "left"])
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), batch + "\n");
    let output = std::process::Command::new(bin)
        .arg("compile")
        .arg(&sp)
        .arg(&lp)
        .arg("missing")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(output.stderr, b"unknown-layer:missing\n");
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn arena_hidden_overlay_long_horizon_direct_model_526() {
    let mut rules = vec![];
    let mut ops = vec![];
    for i in 0..60 {
        let path = format!("v.n{i:02}");
        rules.push(Rule {
            path: path.clone(),
            kind: Kind::Text { nonempty: false },
            required: true,
            secret: false,
        });
        ops.push(Op::Set {
            path,
            value: if i == 59 {
                "done".into()
            } else {
                format!("${{v.n{:02}}}", i + 1)
            },
        });
    }
    let schema = Schema {
        rules,
        constraints: vec![],
    };
    let mut layers = vec![Layer {
        name: "base".into(),
        parents: vec![],
        operations: ops,
    }];
    for i in 0..40 {
        layers.push(Layer {
            name: format!("layer{i:02}"),
            parents: vec![if i == 0 {
                "base".into()
            } else {
                format!("layer{:02}", i - 1)
            }],
            operations: vec![Op::Set {
                path: "v.n59".into(),
                value: format!("value{i}"),
            }],
        });
    }
    let saved_schema = schema.clone();
    let saved_layers = layers.clone();
    let result = arena_hidden_overlay_526::compile(&schema, &layers, "layer39").unwrap();
    assert_eq!(result.layers.len(), 41);
    assert_eq!(result.values["v.n00"].value, Value::Text("value39".into()));
    assert_eq!(result.values["v.n00"].references.len(), 59);
    assert_eq!(result.values["v.n59"].contributors.len(), 1);
    let other = arena_hidden_overlay_526::compile(&schema, &layers, "base").unwrap();
    assert_eq!(other.values["v.n00"].value, Value::Text("done".into()));
    assert_eq!(schema, saved_schema);
    assert_eq!(layers, saved_layers);
}
