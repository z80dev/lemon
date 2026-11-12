use std::collections::HashSet;
use std::fmt::Write;
use crate::args::{decimal, identifier, Options};
struct Record { name: String, kind: String, size: u64 }
fn trim(value: &str) -> &str { value.trim_matches(|c| matches!(c, ' ' | '\t' | '\r')) }
fn parse(input: &str) -> Result<Vec<Record>, String> {
    let mut records = Vec::new();
    let mut names = HashSet::new();
    for (index, line) in input.split('\n').enumerate() {
        let line = trim(line);
        if line.is_empty() || line.starts_with('#') { continue; }
        let fields: Vec<_> = line.split('|').map(trim).collect();
        let error = |message: &str| format!("error: line {}: {message}", index + 1);
        if fields.len() != 3 { return Err(error("expected 3 fields")); }
        if !identifier(fields[0]) { return Err(error("invalid name")); }
        if !identifier(fields[1]) { return Err(error("invalid kind")); }
        let size = decimal(fields[2]).ok_or_else(|| error("invalid size"))?;
        if !names.insert(fields[0].to_owned()) {
            return Err(error(&format!("duplicate name {}", fields[0])));
        }
        records.push(Record { name: fields[0].into(), kind: fields[1].into(), size });
    }
    Ok(records)
}
pub fn transform(input: &str, options: &Options) -> Result<String, String> {
    let mut records = parse(input)?;
    records.retain(|r| options.kind.as_ref().map_or(true, |kind| kind == &r.kind)
        && options.min_size.map_or(true, |minimum| r.size >= minimum));
    match options.sort.as_deref() {
        Some("name") => records.sort_by(|a,b| a.name.cmp(&b.name)),
        Some("size") => records.sort_by(|a,b| a.size.cmp(&b.size).then(a.name.cmp(&b.name))),
        _ => {}
    }
    let mut output = String::new();
    let mut sum = 0u128;
    for record in &records {
        writeln!(output, "{}|{}|{}", record.name, record.kind, record.size).unwrap();
        sum += record.size as u128;
    }
    if options.total { writeln!(output, "total|{}|{}", records.len(), sum).unwrap(); }
    Ok(output)
}
