use rs_ordered_workers::*;
#[test]
fn preserves_order() {
    let result = run_ordered(vec![3,1,4],2,|n|Ok::<_,String>(n*2)).unwrap();
    assert_eq!(result,vec![6,2,8]);
}
#[test]
fn worker_count() {
    assert_eq!(run_ordered(Vec::<u8>::new(),0,|n|Ok::<_,()>(n)),Err(RunError::ZeroWorkers));
    assert_eq!(run_ordered(Vec::<u8>::new(),3,|n|Ok::<_,()>(n)),Ok(vec![]));
}
