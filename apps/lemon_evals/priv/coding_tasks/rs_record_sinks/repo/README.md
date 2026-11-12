# Account report exports

`Record { account: String, amount: i64, note: String }`, `Report { records: Vec<Record>,
include_zero: bool }`, and `ReportError::{EmptyAccount { index: usize }, Overflow { account: String }}`
are public. `note` is metadata and does not affect output. Accounts are case-sensitive and may
contain any nonempty UTF-8 string. Iterate input records in order: reject an empty account at its
zero-based index, and checked-add amounts per account, rejecting the first intermediate i64
overflow even if later records would cancel it. Each account's entries count includes zero amounts.
After validation, output accounts in ascending Rust String order. Drop zero balances unless
include_zero is true. An empty report is valid.

## Shared streaming API to introduce

Re-export at crate root:
```rust
pub trait RecordSink {
    type Error;
    fn begin(&mut self, columns: &[&str]) -> Result<(), Self::Error>;
    fn row(&mut self, values: &[String]) -> Result<(), Self::Error>;
    fn finish(&mut self) -> Result<(), Self::Error>;
}
pub enum EmitError<E> { Invalid(ReportError), Sink(E) }
pub fn emit_report<S: RecordSink>(report: &Report, sink: &mut S)
    -> Result<(), EmitError<S::Error>>;
```
EmitError must derive Debug and PartialEq when E supports them. No extra bounds on S::Error.
Validate the whole report before callbacks. Then call begin once with
`["account", "balance", "entries"]`, row once per included account with three owned Strings
(account, signed decimal balance, decimal entry count), and finish once. Even no rows calls
begin and finish. On the first failed callback return EmitError::Sink with the original error
and perform no later callbacks. Validation errors become EmitError::Invalid.

## Built-in exports to retain and adapt

`CsvSink::new()`, `JsonLinesSink::new()`, each `into_string(self) -> String`, and
`render_csv(&Report) -> Result<String, ReportError>` / `render_jsonl(&Report) -> Result<String, ReportError>`.
Both sink types implement RecordSink with Error = std::convert::Infallible. Their callbacks
are used in the begin/row/finish sequence above. CsvSink emits a header and each row joined
by commas with LF endings, quoting exactly fields containing comma, quote, CR, or LF and
doubling quotes. JsonLinesSink emits no header, and each row is an object with keys in schema
order, all values JSON strings, no spaces, followed by LF. JSON strings escape quote, backslash,
backspace, tab, LF, formfeed, CR with standard short escapes and other U+0000..U+001F as lower-case
`\u00xx`; other Unicode is emitted literally. finish adds nothing for either sink.
Legacy render functions must use the same emit_report path as external sinks: do not maintain
separate grouping/validation/row traversal implementations in the format modules.

Run `cargo test --offline`.
