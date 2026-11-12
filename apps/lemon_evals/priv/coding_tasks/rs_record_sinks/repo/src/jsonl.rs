use crate::{Report, ReportError};
#[derive(Default)]
pub struct JsonLinesSink { output: String }
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
pub fn render_jsonl(report: &Report) -> Result<String, ReportError> {
    let rows = aggregate(report)?;
    let mut sink = JsonLinesSink::new();
    let columns = vec!["account".into(),"balance".into(),"entries".into()];
    for row in rows { line(&mut sink.output,&columns,&row); }
    Ok(sink.into_string())
}
