use rs_journal_replay::{replay, Journal};

#[test]
fn committed_values_and_sequence() {
    let result = replay("1|BEGIN|order
2|PUT|item|blue
3|COMMIT|order
").unwrap();
    assert_eq!(result.values.get("item").map(String::as_str), Some("blue"));
    assert_eq!(result.next_sequence, 4);
}

#[test]
fn pending_values_are_not_visible() {
    let mut journal = Journal::new();
    journal.apply_line("1|BEGIN|draft").unwrap();
    journal.apply_line("2|PUT|note|pending").unwrap();
    assert!(journal.snapshot().values.is_empty());
    assert!(journal.finish().values.is_empty());
}
