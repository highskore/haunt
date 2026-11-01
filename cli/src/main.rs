//! `haunt`: talks to a running haunt over `~/.haunt/ctl` (or `$HAUNT_CTL`); `haunt plugin` works with the app closed.

mod plugin;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::time::Duration;

use serde_json::{Value, json};

const USAGE: &str = "usage: haunt dump\n       haunt decisions [query]\n       haunt plugin <install|list|remove|approve> ...";

fn ctl_path() -> Option<String> {
    std::env::var("HAUNT_CTL").ok().or_else(|| std::env::var("HOME").ok().map(|h| format!("{h}/.haunt/ctl")))
}

fn request(path: &str, req: &Value) -> Result<Value, String> {
    let s = UnixStream::connect(path).map_err(|e| format!("{path}: {e} (is haunt running?)"))?;
    s.set_read_timeout(Some(Duration::from_secs(5))).map_err(|e| e.to_string())?;
    writeln!(&s, "{req}").map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(&s).read_line(&mut line).map_err(|e| e.to_string())?;
    let v: Value = serde_json::from_str(&line).map_err(|e| format!("bad response: {e}"))?;
    if v["ok"] != true {
        return Err(v["error"].as_str().unwrap_or("request failed").to_owned());
    }
    Ok(v)
}

fn run(args: &[String]) -> Result<(), String> {
    let path = ctl_path().ok_or("HOME is not set")?;
    match args {
        [cmd] if cmd == "dump" => {
            let mut v = request(&path, &json!({ "cmd": "dump" }))?;
            v.as_object_mut().map(|o| o.remove("ok"));
            println!("{}", serde_json::to_string_pretty(&v).map_err(|e| e.to_string())?);
        }
        [cmd, rest @ ..] if cmd == "decisions" && rest.len() <= 1 => {
            let query = rest.first().map_or("", String::as_str);
            let v = request(&path, &json!({ "cmd": "decisions", "query": query }))?;
            // One JSON object per line, newest first, so it pipes into jq.
            for d in v["decisions"].as_array().into_iter().flatten() {
                println!("{d}");
            }
        }
        _ => return Err(USAGE.to_owned()),
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|a| a == "plugin") {
        return ExitCode::from(plugin::run(&args[1..]));
    }
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("haunt: {e}");
            ExitCode::FAILURE
        }
    }
}
