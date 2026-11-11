use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
const USAGE: &str = "Usage: manifestctl [--kind KIND] [--min-size N] [--sort name|size] [--total] [FILE|-]\n";
fn invoke(args: &[&str], input: &[u8]) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_manifestctl")).args(args)
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    // Argument failures can close stdin before the writer runs.
    let _ = child.stdin.take().unwrap().write_all(input);
    child.wait_with_output().unwrap()
}
fn good(args: &[&str], input: &str, expected: &str) {
    let out = invoke(args,input.as_bytes());
    assert_eq!(out.status.code(),Some(0),"stderr: {}",String::from_utf8_lossy(&out.stderr));
    assert_eq!(out.stdout,expected.as_bytes());
    assert!(out.stderr.is_empty());
}
fn bad(args: &[&str], input: &[u8], expected: &str) {
    let out = invoke(args,input);
    assert_eq!(out.status.code(),Some(2));
    assert!(out.stdout.is_empty());
    assert_eq!(out.stderr,format!("{expected}\n").as_bytes());
}
#[test]
fn filters_order_and_threshold_are_exact() {
    let input = "# collection\n zebra | data | 010 \r\nalpha|data|5\nbeta|asset|9\nGamma|data|5\nlow|data|4\n";
    good(&[],input,"zebra|data|10\nalpha|data|5\nbeta|asset|9\nGamma|data|5\nlow|data|4\n");
    good(&["--kind","data","--min-size","0005","--sort","size","--total"],input,
        "Gamma|data|5\nalpha|data|5\nzebra|data|10\ntotal|3|20\n");
    good(&["--sort","name"],input,"Gamma|data|5\nalpha|data|5\nbeta|asset|9\nlow|data|4\nzebra|data|10\n");
    good(&["--kind","Data","--total"],input,"total|0|0\n");
    good(&["-","--kind","asset"],input,"beta|asset|9\n");
}
#[test]
fn blanks_crlf_zero_and_large_totals() {
    good(&[]," \t\r\n\t# ignored | anything\r\n","");
    good(&["--total"],"", "total|0|0\n");
    good(&["--min-size","0","--total"],"zero|x|000\r\n", "zero|x|0\ntotal|1|0\n");
    good(&["--total"],"one|x|18446744073709551615\ntwo|x|18446744073709551615",
        "one|x|18446744073709551615\ntwo|x|18446744073709551615\ntotal|2|36893488147419103230\n");
    good(&[],"0-._|9_.-|00012", "0-._|9_.-|12\n");
}
#[test]
fn malformed_records_are_atomic_even_when_filtered_out() {
    for (input,message) in [
        ("ok|x|1\n# comment\n\nwrong", "error: line 4: expected 3 fields"),
        ("ok|x|1\na|b|2|extra", "error: line 2: expected 3 fields"),
        ("|bad space|-1", "error: line 1: invalid name"),
        ("snow雪|x|1", "error: line 1: invalid name"),
        ("a|bad space|-1", "error: line 1: invalid kind"),
        ("a||1", "error: line 1: invalid kind"),
        ("a|x|", "error: line 1: invalid size"),
        ("a|x|-1", "error: line 1: invalid size"),
        ("a|x|+1", "error: line 1: invalid size"),
        ("a|x|18446744073709551616", "error: line 1: invalid size"),
        ("a|x|١", "error: line 1: invalid size"),
        ("a|x|1 # inline", "error: line 1: invalid size"),
        ("a|x|1\na|y|2", "error: line 2: duplicate name a"),
        ("a|x|1\na|bad space|2", "error: line 2: invalid kind"),
        ("a|x|1\na|x|no", "error: line 2: invalid size"),
        ("a b|x|1", "error: line 1: invalid name"),
    ] { bad(&["--kind","absent","--total"],input.as_bytes(),message); }
}
#[test]
fn exact_argument_diagnostics() {
    for (args,message) in [
        (vec!["--unknown"],"error: unknown option --unknown"),
        (vec!["-x"],"error: unknown option -x"),
        (vec!["--kind=data"],"error: unknown option --kind=data"),
        (vec!["--kind"],"error: missing value for --kind"),
        (vec!["--sort"],"error: missing value for --sort"),
        (vec!["--min-size"],"error: missing value for --min-size"),
        (vec!["--kind",""],"error: invalid value for --kind"),
        (vec!["--kind","bad value"],"error: invalid value for --kind"),
        (vec!["--kind","雪"],"error: invalid value for --kind"),
        (vec!["--sort","descending"],"error: invalid value for --sort"),
        (vec!["--sort","--total"],"error: invalid value for --sort"),
        (vec!["--min-size","+1"],"error: invalid value for --min-size"),
        (vec!["--min-size","-1"],"error: invalid value for --min-size"),
        (vec!["--min-size","18446744073709551616"],"error: invalid value for --min-size"),
        (vec!["--min-size",""],"error: invalid value for --min-size"),
        (vec!["--total","--total"],"error: duplicate option --total"),
        (vec!["--kind","x","--kind"],"error: duplicate option --kind"),
        (vec!["--min-size","0","--min-size","bad"],"error: duplicate option --min-size"),
        (vec!["--sort","name","--sort","size"],"error: duplicate option --sort"),
        (vec!["first","second"],"error: multiple input paths"),
        (vec!["--","first","second"],"error: multiple input paths"),
        (vec!["missing-file","--bad"],"error: unknown option --bad"),
    ] { bad(&args,b"also invalid",message); }
}
#[test]
fn help_priority_and_utf8_failures() {
    good(&["--help"],"",USAGE);
    good(&["-h"],"",USAGE);
    for args in [vec!["--help","x"],vec!["--bad","-h"],vec!["--kind","--help"],vec!["--help","--"]] {
        bad(&args,b"", "error: help must be used alone");
    }
    bad(&[], &[0xff], "error: cannot read input");
}
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("manifest-contract-{}-{}",std::process::id(),NEXT.fetch_add(1,Ordering::Relaxed)));
        std::fs::create_dir_all(&path).unwrap(); Self(path)
    }
}
impl Drop for Temp { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }
#[test]
fn file_input_options_after_path_and_end_of_options() {
    let dir = Temp::new();
    let file = dir.0.join("records.txt");
    std::fs::write(&file,"b|data|2\na|asset|3\n").unwrap();
    good(&[file.to_str().unwrap(),"--kind","asset","--total"],"ignored", "a|asset|3\ntotal|1|3\n");
    let non_utf8 = dir.0.join("bytes.txt");
    std::fs::write(&non_utf8,[0xff]).unwrap();
    bad(&[non_utf8.to_str().unwrap()],b"","error: cannot read input");
    let missing = dir.0.join("absent.txt");
    bad(&[missing.to_str().unwrap()],b"","error: cannot read input");
    std::fs::write(dir.0.join("--help"),"item|x|1").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_manifestctl")).args(["--","--help"]).current_dir(&dir.0).output().unwrap();
    assert_eq!(output.status.code(),Some(0));
    assert_eq!(output.stdout,b"item|x|1\n");
    assert!(output.stderr.is_empty());
}
