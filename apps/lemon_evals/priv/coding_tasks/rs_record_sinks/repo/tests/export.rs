use rs_record_sinks::*;
#[test]
fn existing_exports() {
    let report = Report { records: vec![Record {account:"cash".into(),amount:7,note:"deposit".into()}], include_zero:false };
    assert_eq!(render_csv(&report).unwrap(),"account,balance,entries\ncash,7,1\n");
    assert_eq!(render_jsonl(&report).unwrap(),"{\"account\":\"cash\",\"balance\":\"7\",\"entries\":\"1\"}\n");
}
#[test]
fn invalid_before_output() {
    let report = Report {records:vec![Record {account:String::new(),amount:1,note:String::new()}],include_zero:true};
    assert_eq!(render_csv(&report),Err(ReportError::EmptyAccount{index:0}));
}
