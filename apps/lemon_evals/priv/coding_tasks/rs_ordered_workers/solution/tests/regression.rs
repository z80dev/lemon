use rs_ordered_workers::*;
use std::sync::{Arc,atomic::{AtomicUsize,Ordering}};
#[test]
fn continues_after_failure() {
    let count=Arc::new(AtomicUsize::new(0)); let observed=count.clone();
    let result=run_ordered(vec![0,1,2,3],2,move |i| {
        observed.fetch_add(1,Ordering::SeqCst);
        if i==0 {Err("first")} else if i==2 {panic!("third")} else {Ok(i)}
    });
    assert_eq!(result,Err(RunError::Job{index:0,error:"first"}));
    assert_eq!(count.load(Ordering::SeqCst),4);
}
