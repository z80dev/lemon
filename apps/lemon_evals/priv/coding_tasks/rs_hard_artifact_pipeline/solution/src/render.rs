use crate::{EventSource, Report};
pub fn report(report: &Report) -> String {
    let mut lines = vec![
        format!("run={}", report.run),
        format!("roots={}", report.roots.join(",")),
    ];
    for event in &report.events {
        let source = match event.source {
            EventSource::Built => "built",
            EventSource::Cached => "cached",
        };
        lines.push(format!(
            "{source}|{}|{}|{}",
            event.id, event.key, event.output
        ));
    }
    for (id, output) in &report.outputs {
        lines.push(format!("output|{id}|{output}"));
    }
    lines.join(
        "
",
    )
}
