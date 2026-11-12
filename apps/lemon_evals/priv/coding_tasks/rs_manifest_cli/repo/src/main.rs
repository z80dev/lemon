mod args;
mod manifest;
use std::io::{self, Read, Write};
fn run() -> Result<(), String> {
    match args::parse(std::env::args().skip(1).collect())? {
        args::Action::Help => { print!("{}", args::USAGE); Ok(()) }
        args::Action::Transform(options) => {
            let input = match options.path.as_deref() {
                None | Some("-") => {
                    let mut input = String::new();
                    io::stdin().read_to_string(&mut input).map_err(|_| "error: cannot read input".to_owned())?;
                    input
                }
                Some(path) => std::fs::read_to_string(path).map_err(|_| "error: cannot read input".to_owned())?,
            };
            let output = manifest::transform(&input, &options)?;
            io::stdout().write_all(output.as_bytes()).map_err(|_| "error: cannot write output".to_owned())?;
            Ok(())
        }
    }
}
fn main() {
    if let Err(message) = run() { eprintln!("{message}"); std::process::exit(2); }
}
