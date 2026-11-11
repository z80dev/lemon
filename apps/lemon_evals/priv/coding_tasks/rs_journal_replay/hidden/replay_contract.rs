use rs_journal_replay::{replay, ErrorKind as E, Journal, ReplayError};

#[test]
fn rollback_delete_and_last_write_win() {
    let log = "1|BEGIN|a
2|PUT|keep|old
3|PUT|drop|old
4|COMMIT|a
5|BEGIN|b
6|PUT|keep|new
7|DELETE|drop
8|ROLLBACK|b
9|BEGIN|b
10|DELETE|drop
11|DELETE|absent
12|PUT|keep|first
13|PUT|keep| final value 
14|PUT|temp|x
15|DELETE|temp
16|COMMIT|b";
    let result = replay(log).unwrap();
    assert_eq!(result.values.len(), 1);
    assert_eq!(result.values["keep"], " final value ");
    assert_eq!(result.next_sequence, 17);
}

#[test]
fn rejected_records_preserve_pending_and_sequence() {
    let mut j = Journal::new();
    assert_eq!(j.apply_line("1|PUT|k|v"), Err(E::NoTransaction));
    assert_eq!(j.snapshot().next_sequence, 1);
    j.apply_line("1|BEGIN|a").unwrap();
    assert_eq!(j.apply_line("2|BEGIN|b"), Err(E::NestedTransaction));
    j.apply_line("2|PUT|k|v").unwrap();
    assert_eq!(j.apply_line("3|COMMIT|b"), Err(E::TransactionMismatch));
    assert_eq!(j.apply_line("3|ROLLBACK|b"), Err(E::TransactionMismatch));
    assert!(j.snapshot().values.is_empty());
    assert_eq!(j.snapshot().next_sequence, 3);
    j.apply_line("3|COMMIT|a").unwrap();
    assert_eq!(j.snapshot().values["k"], "v");
    for record in ["4|DELETE|k", "4|COMMIT|a", "4|ROLLBACK|a"] {
        assert_eq!(j.apply_line(record), Err(E::NoTransaction));
    }
    j.apply_line("4|BEGIN|a").unwrap();
    j.apply_line("5|ROLLBACK|a").unwrap();
    assert_eq!(j.finish().next_sequence, 6);
}

#[test]
fn parser_is_strict_and_parse_precedes_sequence() {
    for record in ["0|BEGIN|a", "01|BEGIN|a", "+1|BEGIN|a", " 1|BEGIN|a", "١|BEGIN|a",
        "18446744073709551615|BEGIN|a", "18446744073709551616|BEGIN|a", "1|begin|a",
        "1|BEGIN|", "1|BEGIN|a|extra", "1|BEGIN|a.b", "1|BEGIN|é", "1|PUT|k|",
        "1|PUT||v", "1|PUT|k|a|b", "1|DELETE|", "1|DELETE|k|extra", "1|BEGIN|a\r",
        "1|BEGIN|a\n", "1", " ", "9|UNKNOWN|x", "9|PUT|k|"] {
        let mut j = Journal::new();
        assert_eq!(j.apply_line(record), Err(E::Format), "{record:?}");
        assert_eq!(j.snapshot().next_sequence, 1);
    }
    let mut j = Journal::new();
    assert_eq!(j.apply_line("9|COMMIT|a"), Err(E::Sequence { expected: 1, actual: 9 }));
    j.apply_line("1|BEGIN|a_2-X").unwrap();
    assert_eq!(j.apply_line("1|PUT|x|v"), Err(E::Sequence { expected: 2, actual: 1 }));
    j.apply_line("2|PUT|x|雪 ☃").unwrap();
    j.apply_line("3|COMMIT|a_2-X").unwrap();
    assert_eq!(j.finish().values["x"], "雪 ☃");
}

#[test]
fn physical_lines_crlf_and_open_tail() {
    assert_eq!(replay("").unwrap().next_sequence, 1);
    let log = "\r\n1|BEGIN|x\r\n2|PUT|k|v\r\n3|COMMIT|x\r\n\r\n4|BEGIN|tail\r\n5|DELETE|k\r\n";
    let result = replay(log).unwrap();
    assert_eq!(result.values["k"], "v");
    assert_eq!(result.next_sequence, 6);
    assert_eq!(replay("
1|BEGIN|x

2|PUT|k|"), Err(ReplayError { line: 4, kind: E::Format }));
    let mut j = Journal::new();
    j.apply_line("").unwrap();
    j.apply_line("1|BEGIN|x").unwrap();
    j.apply_line("2|COMMIT|x").unwrap();
    assert!(j.finish().values.is_empty());
}
