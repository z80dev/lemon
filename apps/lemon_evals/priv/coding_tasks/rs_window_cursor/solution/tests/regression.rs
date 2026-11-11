use rs_window_cursor::*;
#[test]
fn short_tail_and_huge_batch() {
    let data=[1,2,3,4,5];
    let mut cursor=BatchCursor::new(&data,2).unwrap();
    assert_eq!(cursor.len(),3);
    cursor.next(); cursor.next();
    let last=cursor.next().unwrap();
    assert_eq!(last.offset,4); assert_eq!(last.items,&[5]);
    assert_eq!(cursor.len(),0); assert!(cursor.next().is_none());
    assert_eq!(BatchCursor::new(&data,usize::MAX).unwrap().next().unwrap().items,&data);
}
