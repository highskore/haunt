//! `haunt` command line; works with the app closed.

mod plugin;

const USAGE: &str = "usage: haunt plugin <install|list|remove|approve> ...";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("plugin") => plugin::run(&args[1..]),
        _ => {
            eprintln!("{USAGE}");
            2
        }
    };
    std::process::exit(code);
}
