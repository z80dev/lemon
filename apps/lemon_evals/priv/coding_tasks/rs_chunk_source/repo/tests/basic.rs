use chunk_source::{BytesSource, ChunkSource, ChainSource, LimitSource, ReadExt};
#[test]
fn bytes_are_resumable() {
    let mut source = BytesSource::new(b"hello".to_vec());
    let mut buffer = [0; 2];
    assert_eq!(source.read_chunk(&mut buffer), Ok(2));
    assert_eq!(&buffer, b"he");
    assert_eq!(source.position(), 2);
    let mut tail = Vec::new();
    assert_eq!(source.read_to_end(&mut tail), Ok(3));
    assert_eq!(tail, b"llo");
}
#[test]
fn adapters_can_be_composed() {
    let mut source = ChainSource::new(LimitSource::new(BytesSource::new(b"ab".to_vec()), 2), BytesSource::new(b"cd".to_vec()));
    let mut output = [0; 4];
    source.read_exact(&mut output).unwrap();
    assert_eq!(&output, b"abcd");
}
