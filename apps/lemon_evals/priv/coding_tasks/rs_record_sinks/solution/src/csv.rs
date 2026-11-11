use crate::{Report, ReportError, RecordSink, emit_report};
use std::convert::Infallible;
#[derive(Default)]
pub struct CsvSink { output: String }
impl CsvSink {
    pub fn new() -> Self { Self::default() }
    pub fn into_string(self) -> String { self.output }
}
fn field(value: &str) -> String {
    if value.contains([',', '"', '\r', '\n']) {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else { value.to_string() }
}
fn line(output: &mut String, values: &[String]) {
    for (i,value) in values.iter().enumerate() {
        if i > 0 { output.push(','); }
        output.push_str(&field(value));
    }
    output.push('\n');
}
impl RecordSink for CsvSink {
    type Error = Infallible;
    fn begin(&mut self, columns: &[&str]) -> Result<(), Infallible> {
        line(&mut self.output,&columns.iter().map(|s|s.to_string()).collect::<Vec<_>>());
        Ok(())
    }
    fn row(&mut self, values: &[String]) -> Result<(), Infallible> { line(&mut self.output,values); Ok(()) }
    fn finish(&mut self) -> Result<(), Infallible> { Ok(()) }
}
pub fn render_csv(report: &Report) -> Result<String, ReportError> {
    let mut sink = CsvSink::new();
    crate::stream::rendered(emit_report(report,&mut sink))?;
    Ok(sink.into_string())
}
