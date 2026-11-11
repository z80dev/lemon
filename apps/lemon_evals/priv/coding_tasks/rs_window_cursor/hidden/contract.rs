use rs_window_cursor::*;
#[test]
fn every_boundary_and_hint() {
    for n in 0..48 {
        let data: Vec<_> = (0..n).collect();
        for size in [1,2,3,7,48,49,usize::MAX] {
            let mut it = BatchCursor::new(&data,size).unwrap();
            let expected = n / size + usize::from(n % size != 0);
            for i in 0..expected {
                assert_eq!(it.len(),expected-i);
                assert_eq!(it.size_hint(),(expected-i,Some(expected-i)));
                let b = it.next().unwrap();
                assert_eq!(b.offset,i*size);
                assert_eq!(b.items,&data[b.offset..(b.offset + size.min(n-b.offset))]);
                assert_eq!(b.items.as_ptr(),data[b.offset..].as_ptr());
            }
            assert_eq!(it.len(),0);
            assert_eq!(it.size_hint(),(0,Some(0)));
            assert!(it.next().is_none());
            assert!(it.next().is_none());
        }
    }
}
#[test]
fn nonclone_and_nth() {
    struct Ticket(u8);
    let data = [Ticket(1),Ticket(2),Ticket(3),Ticket(4),Ticket(5)];
    let mut it = BatchCursor::new(&data,2).unwrap();
    assert_eq!(it.nth(1).unwrap().items[0].0,3);
    assert_eq!(it.len(),1);
    assert_eq!(it.next().unwrap().items[0].0,5);
    assert!(it.nth(100).is_none());
    assert!(matches!(BatchCursor::new(&data,0),Err(CursorError::ZeroSize)));
}
