use std::io::Write;
use std::process::{Command, Stdio};
#[test]
fn normalizes_and_sorts_names() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_manifestctl")).args(["--sort","name","--total"])
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(b"z | image | 002\na|text|4\n").unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    assert_eq!(output.stdout,b"a|text|4\nz|image|2\ntotal|2|6\n");
    assert!(output.stderr.is_empty());
}
#[test]
fn help_is_available() {
    let output = Command::new(env!("CARGO_BIN_EXE_manifestctl")).arg("--help").output().unwrap();
    assert!(output.status.success());
    assert!(String::from_utf8(output.stdout).unwrap().starts_with("Usage: manifestctl "));
}
