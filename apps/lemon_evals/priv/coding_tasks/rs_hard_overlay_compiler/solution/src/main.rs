use rs_hard_overlay_compiler::{batch, explain, service};
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(2);
    }
}
fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 4 {
        return Err("usage: compile|explain|batch SCHEMA LAYERS TARGET...".into());
    }
    let schema = std::fs::read_to_string(&args[1])?;
    let layers = std::fs::read_to_string(&args[2])?;
    let result = match args[0].as_str() {
        "compile" if args.len() == 4 || (args.len() == 5 && args[4] == "--reveal") => service::render_text(&schema, &layers, &args[3], args.len() == 4)?,
        "explain" if args.len() == 5 => { let (_, compiled) = service::compile_text(&schema, &layers, &args[3])?; explain::path(&compiled, &args[4])? }
        "batch" => batch::compile_text(&schema, &layers, &args[3..].iter().map(String::as_str).collect::<Vec<_>>(), true)?,
        _ => return Err("usage: compile SCHEMA LAYERS TARGET [--reveal]; explain SCHEMA LAYERS TARGET PATH; batch SCHEMA LAYERS TARGET...".into()),
    };
    println!("{result}");
    Ok(())
}
