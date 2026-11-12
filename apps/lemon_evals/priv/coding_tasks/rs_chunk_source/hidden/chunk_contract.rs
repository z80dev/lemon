use chunk_source::{BytesSource, ChainSource, ChunkSource, ExactError, LimitSource, ReadError, ReadExt};
use std::{cell::Cell, collections::VecDeque, rc::Rc};
#[derive(Clone)]
enum Step { Data(&'static [u8]), Error(ReadError), End }
struct Script { steps: VecDeque<Step>, offset: usize, calls: Rc<Cell<usize>> }
impl Script {
    fn new(steps: Vec<Step>) -> (Self, Rc<Cell<usize>>) {
        let calls = Rc::new(Cell::new(0));
        (Self { steps: steps.into(), offset: 0, calls: calls.clone() }, calls)
    }
}
impl ChunkSource for Script {
    fn read_chunk(&mut self, output: &mut [u8]) -> Result<usize, ReadError> {
        self.calls.set(self.calls.get() + 1);
        if output.is_empty() { return Ok(0); }
        match self.steps.front().cloned().unwrap_or(Step::End) {
            Step::Error(error) => { self.steps.pop_front(); Err(error) }
            Step::End => Ok(0),
            Step::Data(data) => {
                let n = output.len().min(data.len() - self.offset);
                output[..n].copy_from_slice(&data[self.offset..self.offset+n]);
                self.offset += n;
                if self.offset == data.len() { self.offset = 0; self.steps.pop_front(); }
                Ok(n)
            }
        }
    }
}
#[test]
fn bytes_position_empty_and_unchanged_suffix() {
    let mut source = BytesSource::new(b"abc".to_vec());
    assert_eq!(source.read_chunk(&mut []), Ok(0));
    assert_eq!(source.position(), 0);
    let mut out = [b'?'; 5];
    assert_eq!(source.read_chunk(&mut out), Ok(3));
    assert_eq!(&out, b"abc??");
    assert_eq!(source.position(), 3);
    assert_eq!(source.read_chunk(&mut out), Ok(0));
    assert_eq!(&out, b"abc??");
    assert_eq!(BytesSource::new(vec![]).read_chunk(&mut out), Ok(0));
}
#[test]
fn limit_does_not_overread_and_preserves_quota_on_errors() {
    let mut source = LimitSource::new(BytesSource::new(b"abcdef".to_vec()), 3);
    let mut out = [b'?'; 8];
    assert_eq!(source.read_chunk(&mut out), Ok(3));
    assert_eq!(&out, b"abc?????");
    assert_eq!(source.remaining(), 0);
    assert_eq!(source.read_chunk(&mut out), Ok(0));
    let mut inner = source.into_inner();
    assert_eq!(inner.position(), 3);
    assert_eq!(inner.read_chunk(&mut out), Ok(3));
    assert_eq!(&out[..3], b"def");
    let (inner,calls) = Script::new(vec![Step::Error(ReadError::Interrupted), Step::Error(ReadError::Fault("disk")), Step::Data(b"xy"), Step::End]);
    let mut source = LimitSource::new(inner, 5);
    assert_eq!(source.read_chunk(&mut []), Ok(0));
    assert_eq!(calls.get(),0);
    assert_eq!(source.read_chunk(&mut out), Err(ReadError::Interrupted));
    assert_eq!(source.remaining(),5);
    assert_eq!(source.read_chunk(&mut out), Err(ReadError::Fault("disk")));
    assert_eq!(source.remaining(),5);
    assert_eq!(source.read_chunk(&mut out), Ok(2));
    assert_eq!(source.remaining(),3);
    assert_eq!(source.read_chunk(&mut out), Ok(0));
    let before = calls.get();
    assert_eq!(source.read_chunk(&mut out), Ok(0));
    assert_eq!(calls.get(),before);
    assert_eq!(source.remaining(),3);
    let (inner,calls) = Script::new(vec![Step::Data(b"no")]);
    let mut zero = LimitSource::new(inner,0);
    assert_eq!(zero.read_chunk(&mut out),Ok(0));
    assert_eq!(calls.get(),0);
}
#[test]
fn chain_empty_short_errors_and_sticky_end() {
    let (first,a) = Script::new(vec![Step::Error(ReadError::Fault("pause")),Step::Data(b"ab"),Step::End]);
    let (second,b) = Script::new(vec![Step::Error(ReadError::Interrupted),Step::Data(b"cd"),Step::End]);
    let mut source = ChainSource::new(first,second);
    let mut out = [b'?'; 6];
    assert_eq!(source.read_chunk(&mut []),Ok(0));
    assert_eq!((a.get(),b.get()),(0,0));
    assert_eq!(source.read_chunk(&mut out),Err(ReadError::Fault("pause")));
    assert_eq!(b.get(),0);
    assert_eq!(source.read_chunk(&mut out),Ok(2));
    assert_eq!(&out,b"ab????");
    assert_eq!(b.get(),0);
    assert_eq!(source.read_chunk(&mut out),Err(ReadError::Interrupted));
    let first_calls = a.get();
    assert_eq!(source.read_chunk(&mut out),Ok(2));
    assert_eq!(&out,b"cd????");
    assert_eq!(a.get(),first_calls);
    assert_eq!(source.read_chunk(&mut out),Ok(0));
    let last_calls = b.get();
    assert_eq!(source.read_chunk(&mut out),Ok(0));
    assert_eq!(b.get(),last_calls);
    let (_first,_second) = source.into_inner();
}
#[test]
fn exact_errors_count_progress_and_resume() {
    let (mut source,calls) = Script::new(vec![Step::Error(ReadError::Interrupted),Step::Data(b"a"),Step::Error(ReadError::Interrupted),Step::Data(b"bc"),Step::Error(ReadError::Fault("pause")),Step::Data(b"de")]);
    let mut out = [b'?';5];
    assert_eq!(source.read_exact(&mut []),Ok(()));
    assert_eq!(calls.get(),0);
    assert_eq!(source.read_exact(&mut out),Err(ExactError::Source { error:ReadError::Fault("pause"),read:3 }));
    assert_eq!(&out,b"abc??");
    assert_eq!(source.read_exact(&mut out[3..]),Ok(()));
    assert_eq!(&out,b"abcde");
    let mut short = BytesSource::new(b"xy".to_vec());
    let mut out = [b'?';4];
    assert_eq!(short.read_exact(&mut out),Err(ExactError::UnexpectedEof { read:2 }));
    assert_eq!(&out,b"xy??");
    assert_eq!(short.read_exact(&mut out),Err(ExactError::UnexpectedEof { read:0 }));
}
#[test]
fn append_errors_retry_and_trait_object_extensions() {
    let (mut source,_) = Script::new(vec![Step::Data(b"a"),Step::Error(ReadError::Interrupted),Step::Data(b"bc"),Step::Error(ReadError::Fault("pause")),Step::Data(b"de")]);
    let mut out = b"prefix:".to_vec();
    assert_eq!(source.read_to_end(&mut out),Err(ReadError::Fault("pause")));
    assert_eq!(out,b"prefix:abc");
    let object: &mut dyn ChunkSource = &mut source;
    assert_eq!(object.read_to_end(&mut out),Ok(2));
    assert_eq!(out,b"prefix:abcde");
    assert_eq!(object.read_to_end(&mut out),Ok(0));
    let mut bytes = BytesSource::new(vec![42; 4097]);
    let object: &mut dyn ChunkSource = &mut bytes;
    let mut prefix = [0;1];
    assert_eq!(object.read_exact(&mut prefix),Ok(()));
    assert_eq!(prefix,[42]);
    let mut output = vec![9];
    assert_eq!(object.read_to_end(&mut output),Ok(4096));
    assert_eq!(output.len(),4097);
    assert_eq!(output[0],9);
    assert!(output[1..].iter().all(|b| *b==42));
}
#[test]
fn nested_adapters_recover_source_positions() {
    let mut source = LimitSource::new(ChainSource::new(BytesSource::new(b"ab".to_vec()),BytesSource::new(b"cdef".to_vec())),3);
    let mut out = vec![];
    assert_eq!(source.read_to_end(&mut out),Ok(3));
    assert_eq!(out,b"abc");
    let (first, second) = source.into_inner().into_inner();
    assert_eq!(first.position(),2);
    assert_eq!(second.position(),1);
}
