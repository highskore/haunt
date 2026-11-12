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
                ("git", vec!["log".into(), "-n".into(), n.to_string(), "--no-color".into(), "--format=%H%x1f%an%x1f%at%x1f%s".into()])
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

/// Only system and Homebrew locations, never the user's PATH, which an agent's session can change.
const BIN_DIRS: [&str; 4] = ["/opt/homebrew/bin", "/usr/local/bin", "/Library/Developer/CommandLineTools/usr/bin", "/Applications/Xcode.app/Contents/Developer/usr/bin"];

fn binary(name: &str) -> Result<PathBuf, String> {
    BIN_DIRS
        .iter()
        .map(|d| Path::new(d).join(name))
        .find(|p| p.is_file())
        .ok_or_else(|| format!("{name} is not installed in {}", BIN_DIRS.join(", ")))
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

/// Runs `cmd` in `dir` and waits, at most `TIMEOUT`, then kills its whole process group.
pub fn run(cmd: &ExecCommand, dir: &Path) -> Result<ExecOutput, String> {
    let (prog, args) = cmd.argv()?;
    run_argv(&binary(prog)?, &args, dir, TIMEOUT)
}

fn run_argv(bin: &Path, args: &[String], dir: &Path, timeout: Duration) -> Result<ExecOutput, String> {
    let prog = bin.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned());
    let path = BIN_DIRS.iter().chain(&["/usr/bin", "/bin"]).copied().collect::<Vec<_>>().join(":");
    let mut c = Command::new(bin);
    c.args(args)
        .current_dir(dir)
        .env_clear()
        .env("PATH", path)
        .env("LANG", "en_US.UTF-8")
        .env("NO_COLOR", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_PAGER", "cat")
        // A repo's own config could name a program for fsmonitor to run on every status.
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", "core.fsmonitor")
        .env("GIT_CONFIG_VALUE_0", "false")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_SPINNER_DISABLED", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    if let Some(home) = std::env::var_os("HOME") {
        c.env("HOME", home);
    }
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

    #[test]
    fn git_runs_in_the_folder_without_the_repos_fsmonitor() {
        let Ok(_) = binary("git") else { return };
        let dir = crate::testdir::TempDir::created("exec");
        let git = |a: &[&str]| Command::new(binary("git").unwrap()).args(a).current_dir(&*dir).output().unwrap();
        git(&["init", "-q", "-b", "trunk"]);
        let marker = dir.join("ran");
        git(&["config", "core.fsmonitor", &format!("touch {}; false", marker.display())]);
        let o = run(&ExecCommand::GitStatus, &dir).unwrap();
        assert_eq!(o.status, 0, "{o:?}");
        assert!(o.stdout.contains("# branch.head trunk") && !o.truncated, "{o:?}");
        assert!(!marker.exists(), "the repo's fsmonitor must not run");
    }

    #[test]
    fn a_slow_command_and_what_it_started_are_killed_at_the_timeout() {
        let t = Instant::now();
        let args = ["-c", "sleep 30 & echo started; sleep 30"].map(String::from);
        let o = run_argv(Path::new("/bin/sh"), &args, Path::new("/"), Duration::from_millis(300)).unwrap();
        assert_eq!((o.status, o.stdout.as_str()), (-1, "started\n"));
        assert!(t.elapsed() < Duration::from_secs(3), "the backgrounded sleep must not hold the pipe open");
    }

    #[test]
    fn output_is_cut_per_stream() {
        let args = ["-c", "head -c 600000 /dev/zero; echo e >&2"].map(String::from);
        let o = run_argv(Path::new("/bin/sh"), &args, Path::new("/"), TIMEOUT).unwrap();
        assert_eq!((o.status, o.stdout.len(), o.stderr.as_str(), o.truncated), (0, OUTPUT_MAX, "e\n", true));
    }
}
