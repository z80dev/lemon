use crate::{Report, ReportError};
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
fn aggregate(report: &Report) -> Result<Vec<Vec<String>>, ReportError> {
    let mut totals = std::collections::BTreeMap::<String,(i64,usize)>::new();
    for (index,record) in report.records.iter().enumerate() {
        if record.account.is_empty() { return Err(ReportError::EmptyAccount { index }); }
        let (balance,count) = totals.entry(record.account.clone()).or_default();
        *balance = balance.checked_add(record.amount).ok_or_else(|| ReportError::Overflow {account:record.account.clone()})?;
        *count += 1;
    }
    Ok(totals.into_iter().filter(|(_, (n,_))| report.include_zero || *n != 0)
        .map(|(account,(n,count))| vec![account,n.to_string(),count.to_string()]).collect())
}
pub fn render_csv(report: &Report) -> Result<String, ReportError> {
    let rows = aggregate(report)?;
    let mut sink = CsvSink::new();
    line(&mut sink.output,&["account".into(),"balance".into(),"entries".into()]);
    for row in rows { line(&mut sink.output,&row); }
    Ok(sink.into_string())
}
