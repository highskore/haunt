//! Exact-command allow rules for Bash commands the user keeps approving in one project.
//! Nothing is allowed by default: a rule is only written when the user accepts a suggestion.

use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use serde_json::{Value, json};

use crate::decisions::Decision;
use crate::session::Outcome;

pub const SUGGEST_AFTER: u32 = 3;
const MAX_COMMAND: usize = 1024;
const CLAUDE_DIR: &CStr = c".claude";
const SETTINGS: &CStr = c"settings.local.json";

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct AllowSuggestion {
    pub project: String,
    pub command: String,
    /// What goes into `permissions.allow`, e.g. `Bash(cargo test)`.
    pub rule: String,
    pub approvals: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum AllowError {
    #[error("{0} is a symlink")]
    Symlink(String),
    #[error("{0}")]
    Invalid(&'static str),
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

/// The exact rule for `command`, or None if it could not be exact: `*`, `(` and `)` change what
/// a rule matches, and non-printable or non-ASCII text could look like a different command.
pub fn rule_for(command: &str) -> Option<String> {
    let ok = !command.is_empty()
        && command.len() <= MAX_COMMAND
        && command.trim() == command
        && command.bytes().all(|b| (0x20..0x7f).contains(&b) && !b"*()".contains(&b));
    ok.then(|| format!("Bash({command})"))
}

fn is_approval(d: &Decision) -> bool {
    matches!(d.outcome, Outcome::AllowedInHaunt | Outcome::AnsweredInTerminal)
}

/// Commands approved at least `SUGGEST_AFTER` times in the same project, most recently approved first.
/// `skip(project, command)` filters out ones already accepted or dismissed.
pub fn suggestions<'a>(log: impl Iterator<Item = &'a Decision>, skip: impl Fn(&str, &str) -> bool) -> Vec<AllowSuggestion> {
    let mut counts: Vec<(String, String, u32)> = Vec::new();
    for d in log.filter(|d| is_approval(d) && d.tool == "Bash") {
        let Some(project) = d.cwd.as_deref().filter(|c| c.starts_with('/')) else { continue };
        match counts.iter().position(|(p, c, _)| p == project && *c == d.preview) {
            Some(i) => {
                let mut hit = counts.remove(i);
                hit.2 += 1;
                counts.push(hit);
            }
            None => counts.push((project.to_owned(), d.preview.clone(), 1)),
        }
    }
    counts
        .into_iter()
        .rev()
        .filter(|(p, c, n)| *n >= SUGGEST_AFTER && !skip(p, c))
        .filter_map(|(project, command, approvals)| Some(AllowSuggestion { rule: rule_for(&command)?, project, command, approvals }))
        .collect()
}

/// Adds `rule` to `<project>/.claude/settings.local.json`; false if it was already there.
/// Refuses a symlinked `.claude` or settings file, and replaces the file by rename, so a checked-out
/// repo cannot redirect the write.
pub fn add_rule(project: &Path, rule: &str) -> Result<bool, AllowError> {
    if !project.is_absolute() {
        return Err(AllowError::Invalid("project path is not absolute"));
    }
    let root = open_at(None, &CString::new(project.as_os_str().as_bytes()).map_err(|_| AllowError::Invalid("bad path"))?, libc::O_DIRECTORY)?;
    let dir = match open_dir_nofollow(&root, CLAUDE_DIR) {
        Err(AllowError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {
            // SAFETY: valid dirfd and NUL-terminated name.
            if unsafe { libc::mkdirat(root.as_raw_fd(), CLAUDE_DIR.as_ptr(), 0o755) } != 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            open_dir_nofollow(&root, CLAUDE_DIR)?
        }
        r => r?,
    };

    let (content, mode) = match open_at(Some(&dir), SETTINGS, libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK) {
        Ok(fd) => {
            let mut f = File::from(fd);
            let meta = f.metadata()?;
            if !meta.is_file() {
                return Err(AllowError::Invalid("settings.local.json is not a regular file"));
            }
            let mut s = String::new();
            f.read_to_string(&mut s)?;
            (s, meta.permissions().mode() & 0o777)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (String::new(), 0o600),
        Err(_) if is_symlink_at(&dir, SETTINGS) => {
            return Err(AllowError::Symlink(format!("{}/.claude/settings.local.json", project.display())));
        }
        Err(e) => return Err(e.into()),
    };
    let Some(merged) = merge_rule(&content, rule)? else { return Ok(false) };
    write_replace(&dir, &merged, mode)?;
    Ok(true)
}

/// `content` with `rule` appended to `permissions.allow`, or None if present. Content that isn't
/// an object, or a non-object `permissions` or non-array `allow`, is an error and never overwritten.
pub fn merge_rule(content: &str, rule: &str) -> Result<Option<String>, AllowError> {
    let mut root: Value = if content.trim().is_empty() {
        json!({})
    } else {
        // serde's message can quote the file; keep it out of the error.
        serde_json::from_str(content).map_err(|_| AllowError::Invalid("settings.local.json is not valid JSON"))?
    };
    let obj = root.as_object_mut().ok_or(AllowError::Invalid("settings.local.json is not an object"))?;
    let perms = obj.entry("permissions").or_insert_with(|| json!({}));
    let perms = perms.as_object_mut().ok_or(AllowError::Invalid("permissions is not an object"))?;
    let allow = perms.entry("allow").or_insert_with(|| json!([]));
    let allow = allow.as_array_mut().ok_or(AllowError::Invalid("permissions.allow is not an array"))?;
    if allow.iter().any(|v| v.as_str() == Some(rule)) {
        return Ok(None);
    }
    allow.push(rule.into());
    let mut out = serde_json::to_string_pretty(&root).map_err(|_| AllowError::Invalid("cannot encode settings"))?;
    out.push('\n');
    Ok(Some(out))
}

fn open_at(dir: Option<&OwnedFd>, name: &CStr, flags: i32) -> std::io::Result<OwnedFd> {
    let base = dir.map_or(libc::AT_FDCWD, AsRawFd::as_raw_fd);
    // SAFETY: valid dirfd (or AT_FDCWD) and NUL-terminated name; the fd is owned on success.
    let fd: RawFd = unsafe { libc::openat(base, name.as_ptr(), flags | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: fd is a fresh descriptor nobody else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn open_dir_nofollow(dir: &OwnedFd, name: &CStr) -> Result<OwnedFd, AllowError> {
    open_at(Some(dir), name, libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW).map_err(|e| {
        if is_symlink_at(dir, name) { AllowError::Symlink(name.to_string_lossy().into_owned()) } else { e.into() }
    })
}

fn is_symlink_at(dir: &OwnedFd, name: &CStr) -> bool {
    // SAFETY: zeroed stat is a valid out-buffer; dirfd and name are valid.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::fstatat(dir.as_raw_fd(), name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) };
    rc == 0 && st.st_mode & libc::S_IFMT == libc::S_IFLNK
}

/// Writes a temp file next to the settings and renames it over them; rename never follows a link.
fn write_replace(dir: &OwnedFd, content: &str, mode: u32) -> Result<(), AllowError> {
    let tmp = CString::new(format!(".settings.local.json.haunt-{}-{}", std::process::id(), crate::model::hex(&crate::model::random_bytes()[..4])))
        .expect("no NUL");
    let fd = open_at(Some(dir), &tmp, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW)?;
    let mut f = File::from(fd);
    let written = (|| {
        f.set_permissions(std::fs::Permissions::from_mode(mode))?;
        f.write_all(content.as_bytes())?;
        f.sync_all()?;
        // SAFETY: valid dirfds and NUL-terminated names.
        if unsafe { libc::renameat(dir.as_raw_fd(), tmp.as_ptr(), dir.as_raw_fd(), SETTINGS.as_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    })();
    if written.is_err() {
        // SAFETY: valid dirfd and name.
        unsafe { libc::unlinkat(dir.as_raw_fd(), tmp.as_ptr(), 0) };
    }
    Ok(written?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn project(tag: &str) -> PathBuf {
        let d = PathBuf::from(format!("/tmp/ha-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn approval(cwd: &str, cmd: &str, outcome: Outcome) -> Decision {
        Decision { at_ms: 0, surface_id: "s".into(), tool: "Bash".into(), preview: cmd.into(), cwd: Some(cwd.into()), outcome }
    }

    #[test]
    fn suggests_after_three_approvals_of_the_same_command_in_the_same_project() {
        use Outcome::*;
        let mut log = vec![
            approval("/p", "cargo test", AllowedInHaunt),
            approval("/p", "cargo test", AnsweredInTerminal),
            approval("/q", "cargo test", AllowedInHaunt),
            approval("/p", "cargo test", DeniedInHaunt),
            approval("/p", "cargo test", Superseded),
        ];
        assert!(suggestions(log.iter(), |_, _| false).is_empty(), "2 approvals in /p, 1 in /q");
        log.push(approval("/p", "cargo test", AllowedInHaunt));
        let s = suggestions(log.iter(), |_, _| false);
        assert_eq!(s, [AllowSuggestion { project: "/p".into(), command: "cargo test".into(), rule: "Bash(cargo test)".into(), approvals: 3 }]);
        assert!(suggestions(log.iter(), |p, c| p == "/p" && c == "cargo test").is_empty());
    }

    #[test]
    fn never_suggests_wildcards_or_odd_commands() {
        assert_eq!(rule_for("git status").as_deref(), Some("Bash(git status)"));
        for bad in ["", "ls *", "npm run test:*", "echo $(id)", " ls", "echo é", "a\tb"] {
            assert_eq!(rule_for(bad), None, "{bad:?}");
        }
        let log: Vec<_> = (0..3).map(|_| approval("/p", "rm -rf *", Outcome::AllowedInHaunt)).collect();
        assert!(suggestions(log.iter(), |_, _| false).is_empty());
        let other_tool = Decision { tool: "Edit".into(), ..approval("/p", "/p/a.rs", Outcome::AllowedInHaunt) };
        assert!(suggestions([other_tool.clone(), other_tool.clone(), other_tool].iter(), |_, _| false).is_empty());
    }

    #[test]
    fn merges_into_existing_settings_keeping_other_keys() {
        let d = project("merge");
        fs::create_dir(d.join(".claude")).unwrap();
        let path = d.join(".claude/settings.local.json");
        fs::write(&path, r#"{"model":"opus","permissions":{"deny":["Bash(rm)"],"allow":["Read"]}}"#).unwrap();
        assert!(add_rule(&d, "Bash(cargo test)").unwrap());
        assert!(!add_rule(&d, "Bash(cargo test)").unwrap(), "already there");
        let v: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(v["model"], "opus");
        assert_eq!(v["permissions"]["deny"], json!(["Bash(rm)"]));
        assert_eq!(v["permissions"]["allow"], json!(["Read", "Bash(cargo test)"]));
        assert_eq!(fs::read_dir(d.join(".claude")).unwrap().count(), 1, "no temp file left");
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn creates_the_file_when_missing_and_refuses_bad_json() {
        let d = project("new");
        assert!(add_rule(&d, "Bash(ls)").unwrap());
        let path = d.join(".claude/settings.local.json");
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        for bad in ["[1]", "{\"permissions\":[]}", "{\"permissions\":{\"allow\":{}}}", "{oops"] {
            fs::write(&path, bad).unwrap();
            assert!(matches!(add_rule(&d, "Bash(ls)"), Err(AllowError::Invalid(_))), "{bad}");
            assert_eq!(fs::read_to_string(&path).unwrap(), bad, "never overwritten");
        }
        assert!(matches!(add_rule(Path::new("rel"), "Bash(ls)"), Err(AllowError::Invalid(_))));
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn refuses_a_symlinked_settings_file_without_following_it() {
        let d = project("link");
        let outside = project("outside");
        let target = outside.join("victim.json");
        fs::write(&target, "{}").unwrap();
        fs::create_dir(d.join(".claude")).unwrap();
        std::os::unix::fs::symlink(&target, d.join(".claude/settings.local.json")).unwrap();
        assert!(matches!(add_rule(&d, "Bash(ls)"), Err(AllowError::Symlink(_))));
        assert_eq!(fs::read_to_string(&target).unwrap(), "{}", "the link target is untouched");
        assert!(fs::symlink_metadata(d.join(".claude/settings.local.json")).unwrap().file_type().is_symlink());
        fs::remove_dir_all(d).unwrap();
        fs::remove_dir_all(outside).unwrap();
    }

    #[test]
    fn refuses_a_symlinked_claude_dir() {
        let d = project("dirlink");
        let outside = project("dirout");
        std::os::unix::fs::symlink(&outside, d.join(".claude")).unwrap();
        assert!(matches!(add_rule(&d, "Bash(ls)"), Err(AllowError::Symlink(_))));
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 0);
        fs::remove_dir_all(d).unwrap();
        fs::remove_dir_all(outside).unwrap();
    }
}
