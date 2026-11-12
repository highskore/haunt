//! The `exec` capability: a fixed set of read-only git and gh commands, each with fixed arguments, run
//! without a shell in a tab's project folder, off the plugin's thread.

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const TIMEOUT: Duration = Duration::from_secs(10);
/// Per stream.
pub const OUTPUT_MAX: usize = 256 << 10;
pub const MAX_RUNNING: usize = 2;
pub const LOG_MAX: u32 = 50;

/// The manifest's names, as `exec = [...]` lists them.
pub const NAMES: [&str; 6] = ["gh-pr-checks", "gh-pr-view", "git-status", "git-branch", "git-head", "git-log"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExecCommand {
    GhPrChecks,
    GhPrView,
    GitStatus,
    GitBranch,
    GitHead,
    GitLog(u32),
}

impl ExecCommand {
    pub fn name(&self) -> &'static str {
        match self {
            Self::GhPrChecks => "gh-pr-checks",
            Self::GhPrView => "gh-pr-view",
            Self::GitStatus => "git-status",
            Self::GitBranch => "git-branch",
            Self::GitHead => "git-head",
            Self::GitLog(_) => "git-log",
        }
    }

    /// The program and its arguments; nothing in them comes from the plugin but `git-log`'s count.
    fn argv(&self) -> Result<(&'static str, Vec<String>), String> {
        let s = |a: &[&str]| a.iter().map(|&x| x.to_owned()).collect::<Vec<_>>();
        Ok(match self {
            Self::GhPrChecks => ("gh", s(&["pr", "checks", "--json", "name,state,bucket,startedAt,completedAt,link"])),
            Self::GhPrView => ("gh", s(&["pr", "view", "--json", "number,url,title,state,isDraft,headRefName"])),
            // A submodule's own status would need a second git; its commit moving is still reported.
            Self::GitStatus => ("git", s(&["status", "--porcelain=v2", "--branch", "--ignore-submodules=dirty"])),
            Self::GitBranch => ("git", s(&["rev-parse", "--abbrev-ref", "HEAD"])),
            Self::GitHead => ("git", s(&["rev-parse", "HEAD"])),
            Self::GitLog(n) => {
                if !(1..=LOG_MAX).contains(n) {
                    return Err(format!("git-log takes 1 to {LOG_MAX} commits"));
                }
                ("git", vec!["log".into(), "-n".into(), n.to_string(), "--no-color".into(), "--no-show-signature".into(), "--format=%H%x1f%an%x1f%at%x1f%s".into()])
            }
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecOutput {
    /// -1 when it timed out or was killed.
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
}

/// A finished `exec.run` or `fs-list.tree` job, for the plugin that started it.
#[derive(Debug, Clone)]
pub struct ExecDone {
    pub plugin_id: String,
    pub job: u64,
    pub outcome: JobOutcome,
}

#[derive(Debug, Clone)]
pub enum JobOutcome {
    Exec(Result<ExecOutput, String>),
    #[cfg(feature = "plugins")]
    Tree(Result<crate::plugin_fs::Tree, String>),
}

pub type ExecSink = Arc<dyn Fn(ExecDone) + Send + Sync>;

/// Where a command runs: the work tree and its git dir, both canonical. git and gh get them as
/// `GIT_WORK_TREE` and `GIT_DIR`, so discovery can't land in a repository nested inside.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Repo {
    pub work_tree: PathBuf,
    pub git_dir: PathBuf,
}

/// Only system and Homebrew locations, never the user's PATH, which an agent's session can change.
const BIN_DIRS: [&str; 4] = ["/opt/homebrew/bin", "/usr/local/bin", "/Library/Developer/CommandLineTools/usr/bin", "/Applications/Xcode.app/Contents/Developer/usr/bin"];

/// Pinned at command scope, which beats any repo, include or worktree config, and passed to every git gh
/// starts too: nothing a repo's config names (fsmonitor, pager, hooks, external diff, ssh, credential or
/// signing programs, editors) runs, no network, and submodules, which have configs of their own, are skipped.
/// The app's `GitRunner.safeConfig` (macos/Sources/GitDiff.swift) is the same list.
const SAFE_CONFIG: [(&str, &str); 33] = [
    ("core.fsmonitor", "false"), ("core.untrackedCache", "false"), ("core.pager", "cat"), ("core.quotePath", "false"),
    ("core.hooksPath", "/dev/null"), ("core.attributesFile", "/dev/null"), ("diff.external", ""), ("color.ui", "false"),
    ("submodule.recurse", "false"), ("diff.ignoreSubmodules", "all"), ("status.submoduleSummary", "false"),
    ("protocol.allow", "never"), ("protocol.ext.allow", "never"), ("protocol.file.allow", "never"),
    ("protocol.ssh.allow", "never"), ("protocol.http.allow", "never"), ("protocol.https.allow", "never"),
    ("core.sshCommand", ""), ("core.askPass", ""), ("credential.helper", ""), ("gpg.program", ""),
    ("gpg.openpgp.program", ""), ("gpg.x509.program", ""), ("gpg.ssh.program", ""), ("log.showSignature", "false"),
    ("core.editor", "true"), ("sequence.editor", "true"), ("core.alternateRefsCommand", ""), ("core.gitProxy", ""),
    ("diff.noprefix", "false"), ("diff.relative", "false"), ("status.showUntrackedFiles", "normal"), ("core.preloadIndex", "true"),
];

/// git's empty tree: attributes come from it, so no `.gitattributes` can name a filter (git 2.40 and later).
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

fn environment(c: &mut Command) {
    let path = BIN_DIRS.iter().chain(&["/usr/bin", "/bin"]).copied().collect::<Vec<_>>().join(":");
    c.env_clear();
    for (k, v) in [
        ("PATH", path.as_str()), ("LANG", "en_US.UTF-8"), ("NO_COLOR", "1"), ("PAGER", "cat"),
        ("GIT_TERMINAL_PROMPT", "0"), ("GIT_OPTIONAL_LOCKS", "0"), ("GIT_PAGER", "cat"), ("GIT_CONFIG_NOSYSTEM", "1"),
        ("GIT_CONFIG_GLOBAL", "/dev/null"), ("GIT_ATTR_NOSYSTEM", "1"), ("GIT_ATTR_SOURCE", EMPTY_TREE),
        ("GIT_NO_REPLACE_OBJECTS", "1"), ("GIT_NO_LAZY_FETCH", "1"),
        ("GH_PROMPT_DISABLED", "1"), ("GH_NO_UPDATE_NOTIFIER", "1"), ("GH_SPINNER_DISABLED", "1"), ("GH_PAGER", "cat"),
    ] {
        c.env(k, v);
    }
    c.env("GIT_CONFIG_COUNT", SAFE_CONFIG.len().to_string());
    for (i, (k, v)) in SAFE_CONFIG.iter().enumerate() {
        c.env(format!("GIT_CONFIG_KEY_{i}"), k).env(format!("GIT_CONFIG_VALUE_{i}"), v);
    }
    if let Some(home) = std::env::var_os("HOME") {
        c.env("HOME", home);
    }
}

/// `p` with links resolved, if it and every folder up to / belong to root or the user and only they, admin
/// or wheel can write to them, as `GitRunner.trusted` checks: a binary anyone else could replace never runs.
fn trusted(p: &Path) -> Option<PathBuf> {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: getuid has no preconditions.
    let me = unsafe { libc::getuid() };
    let safe = |p: &Path| {
        std::fs::symlink_metadata(p).is_ok_and(|m| {
            (m.uid() == 0 || m.uid() == me) && m.mode() & 0o002 == 0 && (m.mode() & 0o020 == 0 || m.gid() == 0 || m.gid() == 80)
        })
    };
    let real = p.canonicalize().ok()?;
    let m = std::fs::metadata(&real).ok()?;
    (m.is_file() && m.mode() & 0o111 != 0 && real.ancestors().all(safe)).then_some(real)
}

fn binary(name: &str) -> Result<PathBuf, String> {
    BIN_DIRS
        .iter()
        .find_map(|d| trusted(&Path::new(d).join(name)))
        .ok_or_else(|| format!("{name} is not installed in {}, or someone other than you or root can change it", BIN_DIRS.join(", ")))
}

/// Whether the repo's own config (any scope but our pins) defines a filter driver, which `git status` may
/// run on a changed file; reading config runs nothing. Unknown counts as yes.
fn defines_filters(git: &Path, repo: &Repo) -> bool {
    let args = ["config", "--show-scope", "-z", "--get-regexp", r"^filter\."].map(String::from);
    match run_argv("git", git, &[], &args, Some(repo), &repo.work_tree, TIMEOUT) {
        Ok(o) if o.status == 1 => false,
        Ok(o) if o.status == 0 && !o.truncated => {
            let f: Vec<&str> = o.stdout.split('\0').collect();
            f.chunks(2).any(|e| e.len() == 2 && e[0] != "command")
        }
        _ => true,
    }
}

/// macOS's sandbox runner; deprecated by Apple but still shipped, and without it git doesn't run.
#[cfg(target_os = "macos")]
const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

/// A command that runs `bin`, which may start only `children`. On macOS every command runs under
/// `sandbox-exec`: exec is allowed only for the canonical paths of `bin` and `children`, and fork only when
/// there are children, so no filter, hook, pager, fsmonitor, signing or other program a repository could name
/// runs, whatever its config or attributes say and whenever they change. Profiles inherit, so gh's git is
/// held the same way. Elsewhere as is.
fn command(bin: &Path, children: &[&Path]) -> Result<Command, String> {
    #[cfg(target_os = "macos")]
    {
        let mut allowed = String::new();
        let mut real = PathBuf::new();
        for (i, p) in std::iter::once(&bin).chain(children).enumerate() {
            let canon = p.canonicalize().map_err(|e| format!("{}: {e}", p.display()))?;
            let path = canon.to_str().filter(|p| !p.contains(['"', '\\'])).ok_or("a path that can't go in a sandbox profile")?;
            allowed += &format!(" (literal \"{path}\")");
            if i == 0 {
                real = canon;
            }
        }
        if !Path::new(SANDBOX_EXEC).is_file() {
            return Err(format!("{SANDBOX_EXEC} is missing, and Haunt runs nothing outside it"));
        }
        let fork = if children.is_empty() { "(deny process-fork)" } else { "" };
        let mut c = Command::new(SANDBOX_EXEC);
        c.arg("-p").arg(format!("(version 1)(allow default){fork}(deny process-exec)(allow process-exec{allowed})")).arg(real);
        Ok(c)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = children;
        Ok(Command::new(bin))
    }
}

/// Reads at most `OUTPUT_MAX` and drains the rest, so the child never blocks on a full pipe.
fn read_capped(mut r: impl Read) -> (Vec<u8>, bool) {
    let mut out = Vec::new();
    let mut buf = [0u8; 8192];
    let mut cut = false;
    while let Ok(n) = r.read(&mut buf) {
        if n == 0 {
            break;
        }
        let room = OUTPUT_MAX - out.len();
        out.extend_from_slice(&buf[..n.min(room)]);
        cut |= n > room;
    }
    (out, cut)
}

/// Runs `cmd` in `repo` and waits, at most `TIMEOUT`, then kills its whole process group.
pub fn run(cmd: &ExecCommand, repo: &Repo) -> Result<ExecOutput, String> {
    let (prog, args) = cmd.argv()?;
    let bin = binary(prog)?;
    if *cmd == ExecCommand::GitStatus && defines_filters(&bin, repo) {
        return Err("this repository's config defines git filters, which git status could run; Haunt won't".into());
    }
    // gh starts git itself (remote, config, symbolic-ref); nothing else.
    let git = if prog == "gh" { Some(binary("git")?) } else { None };
    run_argv(prog, &bin, git.as_slice(), &args, Some(repo), &repo.work_tree, TIMEOUT)
}

fn run_argv(prog: &str, bin: &Path, children: &[PathBuf], args: &[String], repo: Option<&Repo>, dir: &Path, timeout: Duration) -> Result<ExecOutput, String> {
    let children: Vec<&Path> = children.iter().map(PathBuf::as_path).collect();
    let mut c = command(bin, &children)?;
    environment(&mut c);
    if let Some(r) = repo {
        c.env("GIT_DIR", &r.git_dir).env("GIT_WORK_TREE", &r.work_tree);
    }
    c.args(args).current_dir(dir).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).process_group(0);
    let mut child = c.spawn().map_err(|e| format!("{prog}: {e}"))?;
    let (out, err) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
    let out = std::thread::spawn(move || read_capped(out));
    let err = std::thread::spawn(move || read_capped(err));
    let end = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s.code().unwrap_or(-1),
            Ok(None) if Instant::now() < end => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                // SAFETY: the child leads its own group (`process_group(0)`); this signals only it and what it started.
                unsafe { libc::killpg(child.id() as libc::pid_t, libc::SIGKILL) };
                let _ = child.wait();
                break -1;
            }
        }
    };
    // Whatever the child left running in its group still holds the pipes; end it too.
    // SAFETY: as above; the group id is the reaped child's, and an empty group just errs.
    unsafe { libc::killpg(child.id() as libc::pid_t, libc::SIGKILL) };
    let (out, cut_out) = out.join().unwrap_or_default();
    let (err, cut_err) = err.join().unwrap_or_default();
    let stderr = String::from_utf8_lossy(&err).into_owned();
    // sandbox-exec reports its own failures (a profile it can't apply, a git it can't start) this way.
    if stderr.starts_with("sandbox-exec:") {
        return Err(format!("{prog} couldn't start in its sandbox: {}", stderr.lines().next().unwrap_or_default()));
    }
    Ok(ExecOutput { status, stdout: String::from_utf8_lossy(&out).into_owned(), stderr, truncated: cut_out || cut_err })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_are_fixed_and_the_log_count_is_bounded() {
        assert!(ExecCommand::GitLog(0).argv().is_err() && ExecCommand::GitLog(LOG_MAX + 1).argv().is_err());
        assert_eq!(ExecCommand::GitLog(3).argv().unwrap().1[..3], ["log", "-n", "3"]);
        assert_eq!(NAMES.len(), 6);
        for c in [ExecCommand::GhPrChecks, ExecCommand::GhPrView, ExecCommand::GitStatus, ExecCommand::GitBranch, ExecCommand::GitHead] {
            assert!(NAMES.contains(&c.name()));
        }
    }

    /// A repo whose config names a program everywhere git could run one, each touching `marker`.
    fn hostile_repo(tag: &str) -> (crate::testdir::TempDir, PathBuf) {
        let dir = crate::testdir::TempDir::created(tag);
        let marker = dir.join("ran");
        let evil = dir.join("evil.sh");
        std::fs::write(&evil, format!("#!/bin/sh\ntouch {}\ncat\n", marker.display())).unwrap();
        std::fs::set_permissions(&evil, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        let git = |a: &[&str]| assert!(Command::new(binary("git").unwrap()).args(a).current_dir(&*dir).env("GIT_CONFIG_GLOBAL", "/dev/null").output().unwrap().status.success(), "{a:?}");
        git(&["init", "-q", "-b", "trunk"]);
        std::fs::write(dir.join("a.txt"), "one\n").unwrap();
        git(&["add", "a.txt"]);
        git(&["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "one"]);
        let e = evil.display().to_string();
        for (k, v) in [
            ("core.fsmonitor", e.as_str()), ("core.pager", &e), ("pager.status", &e), ("pager.log", &e), ("gpg.program", &e),
            ("log.showSignature", "true"), ("diff.external", &e), ("core.sshCommand", &e), ("core.hooksPath", "."),
        ] {
            git(&["config", k, v]);
        }
        std::fs::write(dir.join(".gitattributes"), "* filter=evil\n").unwrap();
        std::fs::write(dir.join("a.txt"), "two\n").unwrap();
        (dir, marker)
    }

    fn repo_at(dir: &Path) -> Repo {
        let work_tree = dir.canonicalize().unwrap();
        Repo { git_dir: work_tree.join(".git"), work_tree }
    }

    #[test]
    fn a_hostile_repo_config_runs_nothing() {
        let Ok(_) = binary("git") else { return };
        let (dir, marker) = hostile_repo("exec-hostile");
        let repo = repo_at(&dir);
        let git_cmds = [ExecCommand::GitStatus, ExecCommand::GitBranch, ExecCommand::GitHead, ExecCommand::GitLog(5)];
        for c in &git_cmds {
            let o = run(c, &repo).unwrap();
            assert_eq!(o.status, 0, "{c:?}: {o:?}");
        }
        assert!(run(&ExecCommand::GitStatus, &repo).unwrap().stdout.contains("# branch.head trunk"));
        // A filter in the repo's config could run on any changed file, attributes or not: status is refused.
        Command::new(binary("git").unwrap()).args(["config", "filter.evil.clean", &dir.join("evil.sh").display().to_string()]).current_dir(&*dir).output().unwrap();
        assert!(run(&ExecCommand::GitStatus, &repo).unwrap_err().contains("filters"));
        for c in &git_cmds[1..] {
            assert_eq!(run(c, &repo).unwrap().status, 0, "{c:?}");
        }
        assert!(!marker.exists(), "a program from the repo's config ran");
    }

    /// `git args` in `dir` with nothing pinned but a global config of /dev/null: what the sandbox alone stops.
    /// Run in a pty (`script`), so git also starts a pager.
    #[cfg(target_os = "macos")]
    fn bare_git(sandboxed: bool, dir: &Path, args: &[&str]) -> std::process::Output {
        let git = binary("git").unwrap();
        let inner = if sandboxed { command(&git, &[]).unwrap() } else { Command::new(&git) };
        let mut c = Command::new("/usr/bin/script");
        c.args(["-q", "/dev/null"]).arg(inner.get_program()).args(inner.get_args()).args(args);
        c.current_dir(dir).env("GIT_CONFIG_GLOBAL", "/dev/null").env("GIT_CONFIG_NOSYSTEM", "1").stdin(Stdio::null()).output().unwrap()
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn a_filter_added_after_the_check_never_runs_and_status_still_completes() {
        let Ok(git) = binary("git") else { return };
        let (dir, marker) = hostile_repo("exec-race");
        std::fs::remove_file(dir.join(".gitattributes")).unwrap();
        let repo = repo_at(&dir);
        assert!(!defines_filters(&git, &repo), "nothing defines a filter yet");
        // The race: between the check and the status, the repo gains a filter and an attribute naming it in
        // .git/info/attributes, which GIT_ATTR_SOURCE doesn't cover.
        let evil = dir.join("evil.sh").display().to_string();
        assert!(bare_git(false, &dir, &["config", "filter.evil.clean", &evil]).status.success());
        std::fs::write(dir.join(".git/info/attributes"), "* filter=evil\n").unwrap();
        let args = ExecCommand::GitStatus.argv().unwrap().1;
        let o = run_argv("git", &git, &[], &args, Some(&repo), &repo.work_tree, TIMEOUT).unwrap();
        assert_eq!(o.status, 0, "{o:?}");
        assert!(o.stdout.contains("# branch.head trunk") && o.stdout.contains("a.txt"), "{o:?}");
        assert!(!marker.exists(), "the filter ran");
        // The same status outside the sandbox, all pins kept, does run it: the fixture is a real race.
        let mut c = Command::new(&git);
        environment(&mut c);
        c.args(&args).current_dir(&repo.work_tree).env("GIT_DIR", &repo.git_dir).env("GIT_WORK_TREE", &repo.work_tree).output().unwrap();
        assert!(marker.exists(), "without the sandbox the pins alone let it run");
    }

    /// `dir` gains a filter in its config and an attribute naming it where GIT_ATTR_SOURCE doesn't reach.
    #[cfg(target_os = "macos")]
    fn add_filter(dir: &Path) {
        let evil = dir.join("evil.sh").display().to_string();
        assert!(bare_git(false, dir, &["config", "filter.evil.clean", &evil]).status.success());
        std::fs::write(dir.join(".git/info/attributes"), "* filter=evil\n").unwrap();
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn a_trusted_git_under_another_name_still_runs_sandboxed() {
        let Ok(git) = binary("git") else { return };
        let (dir, marker) = hostile_repo("exec-renamed");
        add_filter(&dir);
        let bin = crate::testdir::TempDir::created("exec-renamed-bin");
        // Not `git-…`: git reads a dashed name as a subcommand.
        let copy = bin.join("scm-tool");
        std::fs::copy(&git, &copy).unwrap();
        let link = bin.join("git");
        std::os::unix::fs::symlink(&copy, &link).unwrap();
        let repo = repo_at(&dir);
        let args = ExecCommand::GitStatus.argv().unwrap().1;
        let o = run_argv("git", &link, &[], &args, Some(&repo), &repo.work_tree, TIMEOUT).unwrap();
        assert!(o.status == 0 && o.stdout.contains("# branch.head trunk"), "{o:?}");
        assert!(!marker.exists(), "the filter ran");
        let mut c = Command::new(&copy);
        environment(&mut c);
        c.args(&args).current_dir(&repo.work_tree).env("GIT_DIR", &repo.git_dir).env("GIT_WORK_TREE", &repo.work_tree).output().unwrap();
        assert!(marker.exists(), "the copy runs filters outside the sandbox, or this test proves nothing");
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn gh_and_the_git_it_starts_stay_in_the_sandbox() {
        let (Ok(gh), Ok(git)) = (binary("gh"), binary("git")) else { return };
        let (dir, marker) = hostile_repo("exec-gh");
        add_filter(&dir);
        let repo = repo_at(&dir);
        // gh starts its git, which runs: the repo has no remote, so gh stops there.
        let view = ["pr", "view"].map(String::from);
        let o = run_argv("gh", &gh, std::slice::from_ref(&git), &view, Some(&repo), &repo.work_tree, TIMEOUT).unwrap();
        assert!(o.stderr.contains("no git remotes"), "{o:?}");
        // gh's git, under the profile it inherits from gh, still can't start the filter.
        let mut c = command(&git, &[&gh]).unwrap();
        environment(&mut c);
        let args = ExecCommand::GitStatus.argv().unwrap().1;
        let o = c.args(&args).current_dir(&repo.work_tree).env("GIT_DIR", &repo.git_dir).env("GIT_WORK_TREE", &repo.work_tree).output().unwrap();
        assert!(o.status.success(), "{o:?}");
        assert!(!marker.exists(), "a filter ran under gh's git");
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn the_sandbox_alone_stops_fsmonitor_pager_and_gpg_programs() {
        let Ok(_) = binary("git") else { return };
        let (dir, marker) = hostile_repo("exec-sandbox");
        let evil = dir.join("evil.sh").display().to_string();
        let fsmonitor = ["-c", &format!("core.fsmonitor={evil}"), "status", "--porcelain"].map(String::from);
        let pager = ["-c", &format!("core.pager={evil}"), "--paginate", "log", "-1"].map(String::from);
        let gpg = ["-c", &format!("gpg.program={evil}"), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qS", "--allow-empty", "-m", "s"].map(String::from);
        for (what, args) in [("fsmonitor", &fsmonitor[..]), ("pager", &pager[..]), ("gpg", &gpg[..])] {
            let args: Vec<&str> = args.iter().map(String::as_str).collect();
            let _ = std::fs::remove_file(&marker);
            bare_git(true, &dir, &args);
            assert!(!marker.exists(), "{what} ran inside the sandbox");
            bare_git(false, &dir, &args);
            assert!(marker.exists(), "{what} should run outside it, or this test proves nothing");
        }
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn git_needs_no_other_process_for_what_haunt_runs() {
        let Ok(_) = binary("git") else { return };
        let dir = crate::testdir::TempDir::created("exec-nofork");
        let sub = crate::testdir::TempDir::created("exec-nofork-sub");
        let git = |d: &Path, a: &[&str]| assert!(bare_git(false, d, a).status.success(), "{a:?}");
        let commit = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "c"];
        git(&sub, &["init", "-q", "-b", "trunk"]);
        git(&sub, &[&commit[..], &["--allow-empty"]].concat());
        git(&dir, &["init", "-q", "-b", "trunk"]);
        git(&dir, &["config", "core.untrackedCache", "true"]);
        git(&dir, &["config", "core.fsmonitor", "true"]);
        std::fs::write(dir.join(".gitattributes"), "*.bin filter=lfs diff=lfs merge=lfs -text\n").unwrap();
        std::fs::write(dir.join("big.bin"), "version https://git-lfs.github.com/spec/v1\noid sha256:0000000000000000000000000000000000000000000000000000000000000000\nsize 1\n").unwrap();
        std::fs::write(dir.join("a.txt"), "one\n").unwrap();
        git(&dir, &["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.to_str().unwrap(), "sub"]);
        git(&dir, &["add", "-A"]);
        git(&dir, &commit);
        git(&dir, &["update-index", "--untracked-cache"]);
        std::fs::write(dir.join("a.txt"), "two\n").unwrap();
        std::fs::write(dir.join("new.txt"), "n\n").unwrap();
        let repo = repo_at(&dir);
        for c in [ExecCommand::GitStatus, ExecCommand::GitBranch, ExecCommand::GitHead, ExecCommand::GitLog(3)] {
            let o = run(&c, &repo).unwrap();
            assert_eq!(o.status, 0, "{c:?}: {o:?}");
            assert!(o.stderr.is_empty(), "{c:?} wanted another process: {}", o.stderr);
        }
        let status = run(&ExecCommand::GitStatus, &repo).unwrap().stdout;
        assert!(status.contains(" a.txt") && status.contains("? new.txt"), "{status}");
        // The review screen's working-tree diff, as macos/Sources/GitDiff.swift runs it.
        let diff = bare_git(true, &dir, &["-c", "core.fsmonitor=false", "--no-pager", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=dirty", "HEAD", "--"]);
        let out = String::from_utf8_lossy(&diff.stdout);
        assert!(diff.status.success() && out.contains("+two") && !out.contains("fork") && !out.contains("not permitted"), "{out}");
    }

    #[test]
    fn only_binaries_no_one_else_can_change_run() {
        let dir = crate::testdir::TempDir::created("exec-trust");
        let bin = dir.join("git");
        std::fs::write(&bin, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&bin, std::os::unix::fs::PermissionsExt::from_mode(0o757)).unwrap();
        assert!(trusted(&bin).is_none(), "world-writable");
        std::fs::set_permissions(&bin, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        // The temp dir's ancestors include the sticky, world-writable /private/tmp parent chain on macOS.
        let tmp_safe = Path::new(&*dir).canonicalize().unwrap().ancestors().all(|a| {
            use std::os::unix::fs::MetadataExt;
            std::fs::symlink_metadata(a).is_ok_and(|m| m.mode() & 0o002 == 0)
        });
        assert_eq!(trusted(&bin).is_some(), tmp_safe);
        assert!(trusted(Path::new("/bin/sh")).is_some());
    }

    #[test]
    fn a_slow_command_and_what_it_started_are_killed_at_the_timeout() {
        let args = ["-c", "sleep 30 & echo \"started $!\"; sleep 30"].map(String::from);
        let t = Instant::now();
        let o = run_argv("sh", Path::new("/bin/sh"), &[PathBuf::from("/bin/bash"), PathBuf::from("/bin/sleep")], &args, None, Path::new("/"), Duration::from_secs(1)).unwrap();
        assert!(t.elapsed() < Duration::from_secs(5), "the backgrounded sleep must not hold the pipe open");
        // Under load the shell may not have printed yet; the kill is what's asserted.
        assert_eq!(o.status, -1);
        let Some(pid) = o.stdout.strip_prefix("started ").and_then(|p| p.trim().parse::<libc::pid_t>().ok()) else {
            assert!("started ".starts_with(o.stdout.as_str()), "{:?}", o.stdout);
            return;
        };
        let dead = || unsafe { libc::kill(pid, 0) } != 0;
        let t = Instant::now();
        while !dead() && t.elapsed() < Duration::from_secs(3) {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(dead(), "the backgrounded sleep {pid} outlived the timeout");
    }

    #[test]
    fn output_is_cut_per_stream() {
        let args = ["-c", "head -c 600000 /dev/zero; echo e >&2"].map(String::from);
        let o = run_argv("sh", Path::new("/bin/sh"), &[PathBuf::from("/bin/bash"), PathBuf::from("/usr/bin/head")], &args, None, Path::new("/"), TIMEOUT).unwrap();
        assert_eq!((o.status, o.stdout.len(), o.stderr.as_str(), o.truncated), (0, OUTPUT_MAX, "e\n", true));
    }
}
