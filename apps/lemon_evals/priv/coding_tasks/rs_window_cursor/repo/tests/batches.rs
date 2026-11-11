use rs_window_cursor::*;
#[test]
fn full_batches() {
    let data = [10,20,30,40];
    let batches: Vec<_> = BatchCursor::new(&data,2).unwrap().collect();
    assert_eq!(batches.len(),2);
    assert_eq!(batches[1].offset,2);
    assert_eq!(batches[1].items,&[30,40]);
}
#[test]
fn invalid_size() { assert!(matches!(BatchCursor::<u8>::new(&[],0),Err(CursorError::ZeroSize))); }
