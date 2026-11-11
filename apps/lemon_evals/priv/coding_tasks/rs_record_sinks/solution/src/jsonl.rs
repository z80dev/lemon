use crate::{Report, ReportError, RecordSink, emit_report};
use std::convert::Infallible;
#[derive(Default)]
pub struct JsonLinesSink { output: String, columns: Vec<String> }
impl JsonLinesSink {
    pub fn new() -> Self { Self::default() }
    pub fn into_string(self) -> String { self.output }
}
fn quoted(value: &str) -> String {
    let mut out = String::from("\"");
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            c if c < ' ' => out.push_str(&format!("\\u{:04x}",c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
fn line(output: &mut String, columns: &[String], values: &[String]) {
    output.push('{');
    for (i,(key,value)) in columns.iter().zip(values).enumerate() {
        if i > 0 { output.push(','); }
        output.push_str(&quoted(key)); output.push(':'); output.push_str(&quoted(value));
    }
    output.push_str("}\n");
}
impl RecordSink for JsonLinesSink {
    type Error = Infallible;
    fn begin(&mut self, columns: &[&str]) -> Result<(), Infallible> {
        self.columns = columns.iter().map(|s|s.to_string()).collect(); Ok(())
    }
    fn row(&mut self, values: &[String]) -> Result<(), Infallible> { line(&mut self.output,&self.columns,values); Ok(()) }
    fn finish(&mut self) -> Result<(), Infallible> { Ok(()) }
}
pub fn render_jsonl(report: &Report) -> Result<String, ReportError> {
    let mut sink = JsonLinesSink::new();
    crate::stream::rendered(emit_report(report,&mut sink))?;
    Ok(sink.into_string())
}
