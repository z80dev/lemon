#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record { pub account: String, pub amount: i64, pub note: String }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report { pub records: Vec<Record>, pub include_zero: bool }
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReportError { EmptyAccount { index: usize }, Overflow { account: String } }
