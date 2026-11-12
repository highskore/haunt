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
            Self::GitStatus => ("git", s(&["status", "--porcelain=v2", "--branch"])),
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

/// A finished job, for the plugin that ran it.
#[derive(Debug, Clone)]
pub struct ExecDone {
    pub plugin_id: String,
    pub job: u64,
    pub outcome: Result<ExecOutput, String>,
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
    match run_argv(git, &args, Some(repo), &repo.work_tree, TIMEOUT) {
        Ok(o) if o.status == 1 => false,
        Ok(o) if o.status == 0 && !o.truncated => {
            let f: Vec<&str> = o.stdout.split('\0').collect();
            f.chunks(2).any(|e| e.len() == 2 && e[0] != "command")
        }
        _ => true,
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
    run_argv(&bin, &args, Some(repo), &repo.work_tree, TIMEOUT)
}

fn run_argv(bin: &Path, args: &[String], repo: Option<&Repo>, dir: &Path, timeout: Duration) -> Result<ExecOutput, String> {
    let prog = bin.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned());
    let mut c = Command::new(bin);
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
    Ok(ExecOutput {
        status,
        stdout: String::from_utf8_lossy(&out).into_owned(),
        stderr: String::from_utf8_lossy(&err).into_owned(),
        truncated: cut_out || cut_err,
    })
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
        let t = Instant::now();
        let args = ["-c", "sleep 30 & echo started; sleep 30"].map(String::from);
        let o = run_argv(Path::new("/bin/sh"), &args, None, Path::new("/"), Duration::from_millis(300)).unwrap();
        assert_eq!((o.status, o.stdout.as_str()), (-1, "started\n"));
        assert!(t.elapsed() < Duration::from_secs(3), "the backgrounded sleep must not hold the pipe open");
    }

    #[test]
    fn output_is_cut_per_stream() {
        let args = ["-c", "head -c 600000 /dev/zero; echo e >&2"].map(String::from);
        let o = run_argv(Path::new("/bin/sh"), &args, None, Path::new("/"), TIMEOUT).unwrap();
        assert_eq!((o.status, o.stdout.len(), o.stderr.as_str(), o.truncated), (0, OUTPUT_MAX, "e\n", true));
    }
}
