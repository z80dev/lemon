use rs_ordered_workers::*;
use std::sync::{Arc,Mutex,Condvar,mpsc,atomic::{AtomicUsize,Ordering}};
use std::time::Duration;
#[derive(Debug,PartialEq)]
struct Output(usize);
#[derive(Debug,PartialEq)]
struct Failure(usize);
struct Input(usize);
#[test]
fn bounded_independent_work_and_order() {
    for (count,workers) in [(3,3),(7,2),(2,usize::MAX),(1,1)] {
        let gate=Arc::new((Mutex::new(false),Condvar::new()));
        let active=Arc::new(AtomicUsize::new(0)); let peak=Arc::new(AtomicUsize::new(0));
        let calls=Arc::new((0..count).map(|_|AtomicUsize::new(0)).collect::<Vec<_>>());
        let (tx,rx)=mpsc::channel();
        let (g,a,p,c)=(gate.clone(),active.clone(),peak.clone(),calls.clone());
        let runner=std::thread::spawn(move || run_ordered((0..count).map(Input).collect(),workers,move |Input(i)| {
            c[i].fetch_add(1,Ordering::SeqCst);
            let running=a.fetch_add(1,Ordering::SeqCst)+1;
            p.fetch_max(running,Ordering::SeqCst);
            tx.send(i).unwrap();
            let (lock,wake)=&*g; let mut open=lock.lock().unwrap();
            while !*open {open=wake.wait(open).unwrap();}
            a.fetch_sub(1,Ordering::SeqCst);
            Ok::<_,Failure>(Output(i*7))
        }));
        let mut starts=0;
        for _ in 0..workers.min(count) {
            if rx.recv_timeout(Duration::from_secs(10)).is_ok() {starts+=1;} else {break;}
        }
        {let (lock,wake)=&*gate; *lock.lock().unwrap()=true; wake.notify_all();}
        let result=runner.join().unwrap().unwrap();
        assert_eq!(starts,workers.min(count),"independent work was serialized");
        assert!(peak.load(Ordering::SeqCst)<=workers);
        assert_eq!(active.load(Ordering::SeqCst),0);
        assert_eq!(result,(0..count).map(|i|Output(i*7)).collect::<Vec<_>>());
        assert!(calls.iter().all(|n|n.load(Ordering::SeqCst)==1));
    }
}
#[test]
fn every_job_runs_after_errors_and_panics() {
    for workers in [1,2,4] {
        let calls=Arc::new((0..9).map(|_|AtomicUsize::new(0)).collect::<Vec<_>>());
        let seen=calls.clone();
        let result=run_ordered((0..9).map(Input).collect(),workers,move |Input(i)| {
            seen[i].fetch_add(1,Ordering::SeqCst);
            if i==4 {panic!("broken transform");}
            if i==1 || i==7 {Err(Failure(i))} else {Ok(Output(i))}
        });
        assert_eq!(result,Err(RunError::Job{index:1,error:Failure(1)}));
        assert!(calls.iter().all(|n|n.load(Ordering::SeqCst)==1));
    }
    let result=run_ordered(vec![Input(0),Input(1),Input(2)],2,|Input(i)| {
        if i==0 {panic!("bad first input");}
        Err::<Output,_>(Failure(i))
    });
    assert_eq!(result,Err(RunError::Panic{index:0}));
}
#[test]
fn failures_are_selected_by_input_not_callback_exit_order() {
    let (tx,rx)=mpsc::channel();
    let receiver=Arc::new(Mutex::new(rx));
    let result=run_ordered(vec![Input(0),Input(1),Input(2)],3,move |Input(i)| {
        if i==0 {
            receiver.lock().unwrap().recv_timeout(Duration::from_secs(10)).unwrap();
            Err::<Output,_>(Failure(90))
        } else if i==1 {
            Err(Failure(1))
        } else {
            tx.send(()).unwrap();
            panic!("later input");
        }
    });
    assert_eq!(result,Err(RunError::Job{index:0,error:Failure(90)}));
}
#[test]
fn zero_empty_and_environment_drop() {
    assert_eq!(run_ordered(vec![Input(1)],0,|_|->Result<Output,Failure>{panic!("must not call")}),Err(RunError::ZeroWorkers));
    assert_eq!(run_ordered(Vec::<Input>::new(),0,|_|Ok::<_,Failure>(Output(0))),Err(RunError::ZeroWorkers));
    assert_eq!(run_ordered(Vec::<Input>::new(),5,|_|Ok::<_,Failure>(Output(0))),Ok(vec![]));
    struct Lifetime(Arc<AtomicUsize>);
    impl Drop for Lifetime {fn drop(&mut self){self.0.fetch_add(1,Ordering::SeqCst);}}
    let dropped=Arc::new(AtomicUsize::new(0)); let lifetime=Lifetime(dropped.clone());
    let result=run_ordered(vec![Input(1),Input(2)],2,move |Input(i)| {
        let _keep=&lifetime; Ok::<_,Failure>(Output(i))
    });
    assert!(result.is_ok()); assert_eq!(dropped.load(Ordering::SeqCst),1);
}
