use rs_hard_artifact_pipeline::{batch, service};
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(2);
    }
}
fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 || !matches!(args[0].as_str(), "build" | "plan" | "batch") {
        return Err("usage: build|plan|batch MANIFEST REQUEST...".into());
    }
    if args[0] != "batch" && args.len() != 3 {
        return Err("usage: build|plan MANIFEST REQUEST".into());
    }
    let manifest = std::fs::read_to_string(&args[1])?;
    let requests: Vec<String> = args[2..]
        .iter()
        .map(std::fs::read_to_string)
        .collect::<Result<_, _>>()?;
    let text = match args[0].as_str() {
        "build" => service::build_text(&manifest, &requests[0])?,
        "plan" => service::plan_text(&manifest, &requests[0])?,
        _ => batch::build_text(
            &manifest,
            &requests.iter().map(String::as_str).collect::<Vec<_>>(),
        )?,
    };
    println!("{text}");
    Ok(())
}
