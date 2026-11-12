use rs_record_sinks::*;
fn record(a:&str,n:i64)->Record {Record{account:a.into(),amount:n,note:"ignored".into()}}
fn report()->Report {Report{records:vec![record("z",3),record("a",2),record("z",-1),record("gone",0),record("a",5)],include_zero:false}}
#[derive(Debug,PartialEq)]
struct Stop(usize);
struct Capture {calls:Vec<String>, rows:Vec<Vec<String>>, fail:Option<usize>}
impl Capture {
    fn new(fail:Option<usize>)->Self {Self{calls:vec![],rows:vec![],fail}}
    fn call(&mut self,name:&str)->Result<(),Stop> {
        let i=self.calls.len(); self.calls.push(name.into());
        if self.fail==Some(i) {Err(Stop(i))} else {Ok(())}
    }
}
impl RecordSink for Capture {
    type Error=Stop;
    fn begin(&mut self,columns:&[&str])->Result<(),Stop> {
        assert_eq!(columns,&["account","balance","entries"]); self.call("begin")
    }
    fn row(&mut self,values:&[String])->Result<(),Stop> {
        self.rows.push(values.to_vec()); self.call("row")
    }
    fn finish(&mut self)->Result<(),Stop> {self.call("finish")}
}
#[test]
fn custom_sink_contract_and_first_failure() {
    let mut sink=Capture::new(None);
    emit_report(&report(),&mut sink).unwrap();
    assert_eq!(sink.calls,["begin","row","row","finish"]);
    assert_eq!(sink.rows,vec![vec!["a","7","2"],vec!["z","2","2"]]);
    for fail in 0..4 {
        let mut sink=Capture::new(Some(fail));
        assert_eq!(emit_report(&report(),&mut sink),Err(EmitError::Sink(Stop(fail))));
        assert_eq!(sink.calls.len(),fail+1);
    }
    let mut empty=Capture::new(None);
    emit_report(&Report{records:vec![],include_zero:false},&mut empty).unwrap();
    assert_eq!(empty.calls,["begin","finish"]);
    let mut r=report(); r.include_zero=true;
    let mut sink=Capture::new(None); emit_report(&r,&mut sink).unwrap();
    assert_eq!(sink.rows[1],vec!["gone","0","1"]);
}
#[test]
fn validation_precedes_all_side_effects() {
    let cases = vec![
        (vec![record("a",1),record("",0)],ReportError::EmptyAccount{index:1}),
        (vec![record("a",i64::MAX),record("a",1),record("a",-1)],ReportError::Overflow{account:"a".into()}),
        (vec![record("b",i64::MIN),record("b",-1),record("",0)],ReportError::Overflow{account:"b".into()}),
    ];
    for (records,error) in cases {
        let r=Report{records,include_zero:false}; let mut sink=Capture::new(Some(0));
        assert_eq!(emit_report(&r,&mut sink),Err(EmitError::Invalid(error.clone())));
        assert!(sink.calls.is_empty());
        assert_eq!(render_csv(&r),Err(error.clone())); assert_eq!(render_jsonl(&r),Err(error));
    }
}
#[test]
fn builtin_sinks_preserve_escaping_and_wrappers() {
    fn infallible<S:RecordSink<Error=std::convert::Infallible>>(_: &S) {}
    let r=Report{records:vec![record("café,\"x\"\n\r",-2),record("slash\\\t\u{8}\u{c}\u{1}",0)],include_zero:true};
    let mut csv=CsvSink::new(); let mut json=JsonLinesSink::new(); infallible(&csv); infallible(&json);
    emit_report(&r,&mut csv).unwrap(); emit_report(&r,&mut json).unwrap();
    let csv=csv.into_string(); let json=json.into_string();
    assert_eq!(render_csv(&r).unwrap(),csv); assert_eq!(render_jsonl(&r).unwrap(),json);
    assert_eq!(csv,"account,balance,entries\n\"café,\"\"x\"\"\n\r\",-2,1\nslash\\\t\u{8}\u{c}\u{1},0,1\n");
    assert_eq!(json,"{\"account\":\"café,\\\"x\\\"\\n\\r\",\"balance\":\"-2\",\"entries\":\"1\"}\n{\"account\":\"slash\\\\\\t\\b\\f\\u0001\",\"balance\":\"0\",\"entries\":\"1\"}\n");
    let empty=Report{records:vec![],include_zero:false};
    assert_eq!(render_csv(&empty).unwrap(),"account,balance,entries\n");
    assert_eq!(render_jsonl(&empty).unwrap(),"");
}
