pub const USAGE: &str = "Usage: manifestctl [--kind KIND] [--min-size N] [--sort name|size] [--total] [FILE|-]\n";
#[derive(Default)]
pub struct Options {
    pub kind: Option<String>,
    pub min_size: Option<u64>,
    pub sort: Option<String>,
    pub total: bool,
    pub path: Option<String>,
}
pub enum Action { Help, Transform(Options) }
pub fn identifier(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
}
pub fn decimal(value: &str) -> Option<u64> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) { return None; }
    value.parse().ok()
}
pub fn parse(args: Vec<String>) -> Result<Action, String> {
    let mut options_enabled = true;
    let mut help = false;
    for arg in &args {
        if options_enabled && arg == "--" { options_enabled = false; }
        else if options_enabled && matches!(arg.as_str(), "--help" | "-h") { help = true; }
    }
    if help {
        return if args.len() == 1 { Ok(Action::Help) }
            else { Err("error: help must be used alone".into()) };
    }
    let mut options = Options::default();
    let mut iter = args.into_iter();
    options_enabled = true;
    while let Some(arg) = iter.next() {
        if options_enabled && arg == "--" { options_enabled = false; continue; }
        if options_enabled && matches!(arg.as_str(), "--kind" | "--min-size" | "--sort" | "--total") {
            let duplicate = match arg.as_str() {
                "--kind" => options.kind.is_some(), "--min-size" => options.min_size.is_some(),
                "--sort" => options.sort.is_some(), _ => options.total,
            };
            if duplicate { return Err(format!("error: duplicate option {arg}")); }
            if arg == "--total" { options.total = true; continue; }
            let value = iter.next().ok_or_else(|| format!("error: missing value for {arg}"))?;
            let invalid = || format!("error: invalid value for {arg}");
            match arg.as_str() {
                "--kind" => { if !identifier(&value) { return Err(invalid()); } options.kind = Some(value); }
                "--min-size" => options.min_size = Some(decimal(&value).ok_or_else(invalid)?),
                _ => { if value != "name" && value != "size" { return Err(invalid()); } options.sort = Some(value); }
            }
        } else if options_enabled && arg.starts_with('-') && arg != "-" {
            return Err(format!("error: unknown option {arg}"));
        } else {
            if options.path.is_some() { return Err("error: multiple input paths".into()); }
            options.path = Some(arg);
        }
    }
    Ok(Action::Transform(options))
}
