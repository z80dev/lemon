use rs_record_sinks::*;
#[derive(Default)]
struct Count { rows:usize }
impl RecordSink for Count {
    type Error = ();
    fn begin(&mut self,_:&[&str])->Result<(),()> {Ok(())}
    fn row(&mut self,_:&[String])->Result<(),()> {self.rows+=1;Ok(())}
    fn finish(&mut self)->Result<(),()> {Ok(())}
}
#[test]
fn external_sink_uses_grouped_rows() {
    let r=Report {records:vec![
        Record{account:"a".into(),amount:2,note:"".into()},
        Record{account:"a".into(),amount:3,note:"".into()},
        Record{account:"z".into(),amount:0,note:"".into()}], include_zero:false};
    let mut sink=Count::default();
    emit_report(&r,&mut sink).unwrap(); assert_eq!(sink.rows,1);
}
