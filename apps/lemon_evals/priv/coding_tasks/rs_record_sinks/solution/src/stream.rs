use crate::{Report, ReportError};
pub trait RecordSink {
    type Error;
    fn begin(&mut self, columns: &[&str]) -> Result<(), Self::Error>;
    fn row(&mut self, values: &[String]) -> Result<(), Self::Error>;
    fn finish(&mut self) -> Result<(), Self::Error>;
}
#[derive(Debug, PartialEq)]
pub enum EmitError<E> { Invalid(ReportError), Sink(E) }
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
pub fn emit_report<S: RecordSink>(report: &Report, sink: &mut S) -> Result<(), EmitError<S::Error>> {
    let rows = aggregate(report).map_err(EmitError::Invalid)?;
    sink.begin(&["account","balance","entries"]).map_err(EmitError::Sink)?;
    for row in rows { sink.row(&row).map_err(EmitError::Sink)?; }
    sink.finish().map_err(EmitError::Sink)
}
pub(crate) fn rendered(result: Result<(), EmitError<std::convert::Infallible>>) -> Result<(), ReportError> {
    match result {
        Ok(()) => Ok(()),
        Err(EmitError::Invalid(e)) => Err(e),
        Err(EmitError::Sink(e)) => match e {},
    }
}
