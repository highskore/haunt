//! `haunt setup` against the real adapters' install.sh, in a temp HOME with a `claude` shim that logs its arguments.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

fn adapters() -> Option<(PathBuf, PathBuf)> {
    let base = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../haunt-plugins");
    let (c, x) = (base.join("haunt-claude"), base.join("haunt-codex"));
    if c.join("install.sh").is_file() && x.join("install.sh").is_file() {
        Some((c.canonicalize().unwrap(), x.canonicalize().unwrap()))
    } else {
        eprintln!("skipping: haunt-claude and haunt-codex are not checked out beside this repo");
        None
    }
}

struct Env {
    root: PathBuf,
    claude: PathBuf,
    codex: PathBuf,
    shim: bool,
}

impl Env {
    fn new(name: &str, (claude, codex): (PathBuf, PathBuf)) -> Self {
        let root = std::env::temp_dir().join(format!("haunt-setup-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for d in ["home", "bin", "haunt", "codex"] {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
        let root = root.canonicalize().unwrap();
        for tool in ["claude", "codex"] {
            let p = root.join("bin").join(tool);
            let log = root.join(format!("{tool}.log"));
            let script = format!("#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n[ -z \"$SHIM_FAIL\" ]\n", log.display());
            std::fs::write(&p, script).unwrap();
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        Env { root, claude, codex, shim: true }
    }

    fn path(&self) -> String {
        let sys = "/usr/bin:/bin:/usr/sbin:/sbin";
        if self.shim { format!("{}:{sys}", self.root.join("bin").display()) } else { sys.to_owned() }
    }

    fn cmd(&self, args: &[&str]) -> Command {
        self.cmd_bin(Path::new(env!("CARGO_BIN_EXE_haunt")), args)
    }

    fn cmd_bin(&self, bin: &Path, args: &[&str]) -> Command {
        let mut c = Command::new(bin);
        // A clean environment: nothing can reach the real ~/.claude, ~/.codex or ~/.haunt.
        c.env_clear()
            .args(args)
            .env("PATH", self.path())
            .env("HOME", self.root.join("home"))
            .env("HAUNT_CONFIG_DIR", self.root.join("haunt"))
            .env("CODEX_HOME", self.root.join("codex"))
            .env("CLAUDE_CONFIG_DIR", self.root.join("home/.claude"))
            .env("HAUNT_CLAUDE_ADAPTER", &self.claude)
            .env("HAUNT_CODEX_ADAPTER", &self.codex);
        c
    }

    fn run(&self, args: &[&str], stdin: &str) -> Output {
        self.run_with(self.cmd(args), stdin)
    }

    fn run_with(&self, mut c: Command, stdin: &str) -> Output {
        assert_eq!(self.which("claude"), self.shim.then(|| self.root.join("bin/claude")), "claude must resolve to the shim");
        let mut child = c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
        child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
        child.wait_with_output().unwrap()
    }

    fn which(&self, tool: &str) -> Option<PathBuf> {
        self.path().split(':').map(|d| Path::new(d).join(tool)).find(|p| p.is_file())
    }

    fn log(&self, tool: &str) -> String {
        std::fs::read_to_string(self.root.join(format!("{tool}.log"))).unwrap_or_default()
    }

    fn agents(&self) -> Option<serde_json::Value> {
        let s = std::fs::read_to_string(self.root.join("haunt/state.json")).ok()?;
        Some(serde_json::from_str::<serde_json::Value>(&s).unwrap()["agents"].clone())
    }

    fn config(&self) -> Option<String> {
        std::fs::read_to_string(self.root.join("codex/config.toml")).ok()
    }

    /// The staged copies of an agent's adapter under the temp ~/.haunt.
    fn staged_all(&self, agent: &str) -> Vec<PathBuf> {
        let Ok(rd) = std::fs::read_dir(self.root.join("haunt/adapters").join(agent)) else { return vec![] };
        rd.map(|e| e.unwrap().path()).collect()
    }

    fn staged(&self, agent: &str) -> PathBuf {
        let all = self.staged_all(agent);
        assert_eq!(all.len(), 1, "{all:?}");
        all[0].clone()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn text(o: &Output) -> String {
    format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr))
}

fn install_cmds(dir: &Path) -> String {
    format!("plugin marketplace add {}\nplugin install haunt@haunt\n", dir.display())
}

#[test]
fn dry_run_prints_the_change_and_changes_nothing() {
    let Some(a) = adapters() else { return };
    let e = Env::new("dry", a);
    let o = e.run(&["setup", "claude", "codex", "--dry-run"], "");
    let out = text(&o);
    assert!(o.status.success(), "{out}");
    assert!(out.contains(&format!("  claude plugin marketplace add {}\n", e.staged("claude").display())), "{out}");
    assert!(out.contains("  claude plugin install haunt@haunt\n"), "{out}");
    assert!(out.contains(&format!("  +++ {}", e.root.join("codex/config.toml").display())), "{out}");
    assert!(out.contains("  +# >>> haunt-codex >>>"), "{out}");
    assert!(out.contains("Then Haunt records claude and codex in"), "{out}");
    assert!(!out.contains("Apply?"), "{out}");
    assert_eq!((e.log("claude"), e.log("codex"), e.agents(), e.config()), (String::new(), String::new(), None, None));

    let o = e.run(&["setup", "--remove", "claude", "--dry-run"], "");
    assert!(o.status.success() && text(&o).contains("  claude plugin uninstall haunt@haunt\n"), "{}", text(&o));
    assert_eq!((e.log("claude"), e.agents()), (String::new(), None));
}

#[test]
fn interactive_asks_which_agents_then_y_or_n() {
    let Some(a) = adapters() else { return };
    let e = Env::new("ask", a);
    let o = e.run(&["setup"], "3\nn\n");
    let out = text(&o);
    assert!(o.status.success(), "{out}");
    assert!(out.contains("Which agents should Haunt set up?") && out.contains("Apply? [y/N]"), "{out}");
    assert!(out.contains("claude plugin install haunt@haunt") && out.contains("+# >>> haunt-codex >>>"), "{out}");
    assert!(out.contains("nothing changed"), "{out}");
    assert_eq!((e.log("claude"), e.agents(), e.config()), (String::new(), None, None));

    // Enter alone, or end of input, is a no.
    for answer in ["1\n\n", "1\n"] {
        let o = e.run(&["setup"], answer);
        assert!(o.status.success() && text(&o).contains("nothing changed"), "{}", text(&o));
        assert_eq!((e.log("claude"), e.agents()), (String::new(), None));
    }

    let o = e.run(&["setup"], "1\ny\n");
    assert!(o.status.success(), "{}", text(&o));
    assert_eq!(e.log("claude"), install_cmds(&e.staged("claude")));
    assert_eq!(e.agents(), Some(serde_json::json!(["claude"])));
    assert_eq!(e.config(), None, "Codex wasn't chosen");

    let o = e.run(&["setup"], "9\n");
    assert_eq!(o.status.code(), Some(1), "{}", text(&o));
    assert_eq!(e.log("codex"), "", "codex itself is never run");
}

#[test]
fn just_the_terminal_records_the_choice_and_changes_nothing() {
    let Some(a) = adapters() else { return };
    let e = Env::new("none", a);
    let o = e.run(&["setup"], "4\n");
    assert!(o.status.success() && text(&o).contains("no agent config changes"), "{}", text(&o));
    assert_eq!(e.agents(), Some(serde_json::json!([])));
    assert_eq!((e.log("claude"), e.config()), (String::new(), None));

    let o = e.run(&["setup", "none", "--dry-run"], "");
    assert!(o.status.success());
    let o = e.run(&["setup", "none"], "");
    assert!(o.status.success());
    assert_eq!(e.agents(), Some(serde_json::json!([])));
}

#[test]
fn yes_applies_and_remove_reverts() {
    let Some(a) = adapters() else { return };
    let e = Env::new("yes", a);
    let original = "model = \"o3\"\n";
    std::fs::write(e.root.join("codex/config.toml"), original).unwrap();
    std::fs::write(e.root.join("haunt/state.json"), r#"{"sidebar_hidden":true}"#).unwrap();

    let o = e.run(&["setup", "claude", "codex", "--yes"], "");
    let out = text(&o);
    assert!(o.status.success(), "{out}");
    assert!(!out.contains("Apply?"), "{out}");
    assert_eq!(e.log("claude"), install_cmds(&e.staged("claude")));
    let config = e.config().unwrap();
    assert!(config.starts_with(original) && config.contains("# >>> haunt-codex >>>"), "{config}");
    assert!(config.contains(&format!("command = \"{}/bin/haunt-codex-hook\"", e.staged("codex").display())), "{config}");
    let state: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(e.root.join("haunt/state.json")).unwrap()).unwrap();
    assert_eq!(state, serde_json::json!({ "sidebar_hidden": true, "agents": ["claude", "codex"] }));

    let o = e.run(&["setup", "--remove", "codex", "--yes"], "");
    assert!(o.status.success(), "{}", text(&o));
    assert_eq!(e.config().as_deref(), Some(original));
    assert_eq!(e.agents(), Some(serde_json::json!(["claude"])));
    assert!(e.staged_all("codex").is_empty(), "removal drops the staged copy");

    let claude = e.staged("claude");

    let o = e.run(&["setup", "--remove", "claude"], "y\n");
    assert!(o.status.success(), "{}", text(&o));
    assert_eq!(
        e.log("claude"),
        install_cmds(&claude) + "plugin uninstall haunt@haunt\nplugin marketplace remove haunt\n"
    );
    assert!(e.staged_all("claude").is_empty());
    assert_eq!(e.agents(), Some(serde_json::json!([])));
    assert_eq!(e.log("codex"), "");
}

#[test]
fn unknown_agent_and_bad_flags_change_nothing() {
    let Some(a) = adapters() else { return };
    let e = Env::new("unknown", a);
    let o = e.run(&["setup", "gemini"], "");
    assert_eq!(o.status.code(), Some(2));
    assert!(text(&o).contains("unknown agent \"gemini\""), "{}", text(&o));
    for args in [
        &["setup", "--remove"][..],
        &["setup", "--yes"],
        &["setup", "none", "claude"],
        &["setup", "--remove", "none"],
        &["setup", "claude", "--force"],
    ] {
        let o = e.run(args, "");
        assert_eq!(o.status.code(), Some(2), "{args:?}: {}", text(&o));
    }
    assert_eq!((e.log("claude"), e.agents(), e.config()), (String::new(), None, None));
}

#[test]
fn missing_adapter_is_an_error() {
    let e = Env::new("missing", (PathBuf::from("/nonexistent/haunt-claude"), PathBuf::from("/nonexistent/haunt-codex")));
    for agent in ["claude", "codex"] {
        let o = e.run(&["setup", agent, "--yes"], "");
        assert_eq!(o.status.code(), Some(1));
        let out = text(&o);
        assert!(out.contains("adapter is not at /nonexistent/haunt-") && out.contains("_ADAPTER"), "{out}");
    }
    // An empty folder is not an adapter either.
    let mut c = e.cmd(&["setup", "claude", "--dry-run"]);
    c.env("HAUNT_CLAUDE_ADAPTER", e.root.join("home"));
    let o = e.run_with(c, "");
    assert_eq!(o.status.code(), Some(1), "{}", text(&o));
    assert_eq!((e.log("claude"), e.agents(), e.config()), (String::new(), None, None));
}

#[test]
fn claude_missing_or_failing_records_nothing() {
    let Some(a) = adapters() else { return };
    let mut e = Env::new("noclaude", a);
    e.shim = false;
    let o = e.run(&["setup", "claude", "--yes"], "");
    assert_eq!(o.status.code(), Some(1));
    assert!(text(&o).contains("claude is not on PATH"), "{}", text(&o));
    // A dry run needs no claude.
    assert!(e.run(&["setup", "claude", "--dry-run"], "").status.success());
    assert_eq!(e.agents(), None);

    e.shim = true;
    let mut c = e.cmd(&["setup", "claude", "--yes"]);
    c.env("SHIM_FAIL", "1");
    let o = e.run_with(c, "");
    assert_eq!(o.status.code(), Some(1), "{}", text(&o));
    assert!(text(&o).contains("--apply failed for Claude Code"), "{}", text(&o));
    assert_eq!(e.log("claude"), format!("plugin marketplace add {}\n", e.staged("claude").display()));
    assert_eq!(e.agents(), None);
}

fn copy_dir(from: &Path, to: &Path) {
    let st = Command::new("/bin/cp").arg("-R").arg(from).arg(to).status().unwrap();
    assert!(st.success());
}

fn preview_sha(o: &Output) -> String {
    let out = String::from_utf8_lossy(&o.stdout);
    out.lines().find_map(|l| l.strip_prefix("preview sha256 ")).expect("a preview hash").to_owned()
}

#[test]
fn installs_run_from_a_stable_copy_that_outlives_the_source() {
    let Some(a) = adapters() else { return };
    let e = Env::new("stage", a);
    let src = e.root.join("src-claude");
    copy_dir(&e.claude, &src);
    let run = |args: &[&str]| {
        let mut c = e.cmd(args);
        c.env("HAUNT_CLAUDE_ADAPTER", &src);
        e.run_with(c, "")
    };

    let o = run(&["setup", "claude", "--yes"]);
    assert!(o.status.success(), "{}", text(&o));
    let first = e.staged("claude");
    assert!(first.starts_with(e.root.join("haunt/adapters/claude")), "{first:?}");
    assert!(first.join(".claude-plugin/plugin.json").is_file() && !first.join(".git").exists());
    let mode = std::fs::metadata(first.join("install.sh")).unwrap().permissions().mode();
    assert_eq!(mode & 0o111, 0o111, "install.sh stays executable");
    assert_eq!(e.log("claude"), install_cmds(&first));

    // The same content stages to the same place; changed content gets a new copy and the old one goes.
    assert!(run(&["setup", "claude", "--dry-run"]).status.success());
    assert_eq!(e.staged("claude"), first);
    std::fs::write(src.join("README.md"), "changed\n").unwrap();
    let o = run(&["setup", "claude", "--yes"]);
    assert!(o.status.success(), "{}", text(&o));
    let second = e.staged("claude");
    assert_ne!(second, first);
    assert!(e.log("claude").ends_with(&install_cmds(&second)));

    // Rebuilding or moving the app takes the source away; the install still points at a real folder.
    std::fs::remove_dir_all(&src).unwrap();
    assert!(second.join("install.sh").is_file());
}

#[test]
fn a_translocated_app_is_refused() {
    let Some(a) = adapters() else { return };
    let e = Env::new("transloc", a);
    let src = e.root.join("AppTranslocation/0A1B/d/haunt.app/Contents/Resources/adapters");
    std::fs::create_dir_all(&src).unwrap();
    copy_dir(&e.claude, &src.join("claude"));
    let mut c = e.cmd(&["setup", "claude", "--dry-run"]);
    c.env("HAUNT_CLAUDE_ADAPTER", src.join("claude"));
    let o = e.run_with(c, "");
    assert_eq!(o.status.code(), Some(1), "{}", text(&o));
    assert!(text(&o).contains("Move haunt.app to /Applications"), "{}", text(&o));
    assert!(!e.root.join("haunt/adapters").exists());
    assert_eq!((e.log("claude"), e.agents()), (String::new(), None));
}

#[test]
fn expect_applies_only_the_previewed_change() {
    let Some(a) = adapters() else { return };
    let e = Env::new("expect", a);
    let o = e.run(&["setup", "codex", "--dry-run"], "");
    assert!(o.status.success(), "{}", text(&o));
    let sha = preview_sha(&o);
    assert_eq!(sha.len(), 64);
    assert_eq!(preview_sha(&e.run(&["setup", "codex", "--dry-run"], "")), sha, "previews are stable");

    // The config changed after the preview: the fresh change differs, so nothing is applied.
    std::fs::write(e.root.join("codex/config.toml"), "model = \"o3\"\n").unwrap();
    let o = e.run(&["setup", "codex", "--yes", "--expect", &sha], "");
    assert_eq!(o.status.code(), Some(1), "{}", text(&o));
    assert!(text(&o).contains("differs from the preview"), "{}", text(&o));
    assert_eq!((e.config().as_deref(), e.agents()), (Some("model = \"o3\"\n"), None));

    let sha = preview_sha(&e.run(&["setup", "codex", "--dry-run"], ""));
    let o = e.run(&["setup", "codex", "--yes", "--expect", &sha], "");
    assert!(o.status.success(), "{}", text(&o));
    assert!(e.config().unwrap().contains("# >>> haunt-codex >>>"));
    assert_eq!(e.agents(), Some(serde_json::json!(["codex"])));

    assert_eq!(e.run(&["setup", "codex", "--expect"], "").status.code(), Some(2));
}

#[test]
fn a_symlinked_cli_finds_the_adapters_in_its_bundle() {
    let Some(a) = adapters() else { return };
    let e = Env::new("symlink", a);
    let contents = e.root.join("haunt.app/Contents");
    std::fs::create_dir_all(contents.join("Helpers")).unwrap();
    std::fs::create_dir_all(contents.join("Resources/adapters")).unwrap();
    std::fs::copy(env!("CARGO_BIN_EXE_haunt"), contents.join("Helpers/haunt")).unwrap();
    copy_dir(&e.claude, &contents.join("Resources/adapters/claude"));
    let link = e.root.join("bin/haunt");
    std::os::unix::fs::symlink(contents.join("Helpers/haunt"), &link).unwrap();

    let mut c = e.cmd_bin(&link, &["setup", "claude", "--dry-run"]);
    c.env_remove("HAUNT_CLAUDE_ADAPTER");
    let o = e.run_with(c, "");
    assert!(o.status.success(), "{}", text(&o));
    let want = format!("the adapter from {},", contents.join("Resources/adapters/claude").display());
    assert!(text(&o).contains(&want), "{}", text(&o));
}
