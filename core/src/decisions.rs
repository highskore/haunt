//! Every verified permission request and how it ended: in memory, plus `<config_dir>/decisions.jsonl`.

use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::session::{Outcome, Permission};

pub const FILE_NAME: &str = "decisions.jsonl";
const MAX_IN_MEMORY: usize = 10_000;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Decision {
    /// Unix time in milliseconds.
    pub at_ms: u64,
    pub surface_id: String,
    pub tool: String,
    pub preview: String,
    pub cwd: Option<String>,
    pub outcome: Outcome,
}

impl Decision {
    pub fn new(surface_id: &str, p: &Permission, outcome: Outcome) -> Self {
        let at_ms = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64);
        Self { at_ms, surface_id: surface_id.to_owned(), tool: p.tool.clone(), preview: p.preview(), cwd: p.cwd.clone(), outcome }
    }

    fn matches(&self, needle: &str) -> bool {
        let outcome = serde_json::to_string(&self.outcome).unwrap_or_default();
        [self.tool.as_str(), &self.preview, self.cwd.as_deref().unwrap_or(""), &outcome, &self.surface_id]
            .iter()
            .any(|h| h.to_lowercase().contains(needle))
    }
}

#[derive(Default)]
pub struct DecisionLog {
    entries: VecDeque<Decision>,
    file: Option<File>,
}

impl DecisionLog {
    /// Opens (0600, no symlinks) and loads `<dir>/decisions.jsonl`; `dir` must already be secured.
    pub fn open(&mut self, dir: &Path) -> std::io::Result<()> {
        // A `start` that failed after this point may be retried; loading twice would duplicate entries.
        if self.file.is_some() {
            return Ok(());
        }
        let path = dir.join(FILE_NAME);
        let mut file = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&path)?;
        let meta = file.metadata()?;
        if !meta.is_file() || meta.uid() != crate::intake::uid() {
            return Err(std::io::Error::other(format!("{} is not a file of ours", path.display())));
        }
        if meta.mode() & 0o077 != 0 {
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        }
        file.seek(SeekFrom::Start(0))?;
        let mut loaded: VecDeque<Decision> = VecDeque::new();
        for line in BufReader::new(&file).lines() {
            let Ok(d) = serde_json::from_str::<Decision>(&line?) else { continue };
            if loaded.len() == MAX_IN_MEMORY {
                loaded.pop_front();
            }
            loaded.push_back(d);
        }
        // Anything recorded before the file was open goes to disk now.
        for d in &self.entries {
            write_line(&mut file, d);
        }
        loaded.extend(self.entries.drain(..));
        while loaded.len() > MAX_IN_MEMORY {
            loaded.pop_front();
        }
        self.entries = loaded;
        self.file = Some(file);
        Ok(())
    }

    pub fn record(&mut self, d: Decision) {
        if let Some(f) = &mut self.file {
            write_line(f, &d);
        }
        if self.entries.len() == MAX_IN_MEMORY {
            self.entries.pop_front();
        }
        self.entries.push_back(d);
    }

    /// Newest first; `query` is a case-insensitive substring of tool, preview, cwd, outcome or surface.
    pub fn query(&self, query: &str, limit: usize) -> Vec<Decision> {
        let needle = query.trim().to_lowercase();
        self.entries.iter().rev().filter(|d| needle.is_empty() || d.matches(&needle)).take(limit).cloned().collect()
    }

    pub fn iter(&self) -> impl Iterator<Item = &Decision> {
        self.entries.iter()
    }
}

fn write_line(f: &mut File, d: &Decision) {
    let Ok(mut line) = serde_json::to_string(d) else { return };
    line.push('\n');
    // One write on an O_APPEND fd keeps lines whole; a failed write still leaves the memory copy.
    let _ = f.write_all(line.as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn dir(tag: &str) -> PathBuf {
        let d = PathBuf::from(format!("/tmp/hd-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn decision(preview: &str, outcome: Outcome) -> Decision {
        Decision { at_ms: 1, surface_id: "s".into(), tool: "Bash".into(), preview: preview.into(), cwd: Some("/p".into()), outcome }
    }

    #[test]
    fn persists_as_private_jsonl_and_reloads() {
        let d = dir("persist");
        let mut log = DecisionLog::default();
        log.record(decision("before open", Outcome::Superseded));
        log.open(&d).unwrap();
        log.record(decision("git push", Outcome::AllowedInHaunt));
        let path = d.join(FILE_NAME);
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        let text = fs::read_to_string(&path).unwrap();
        assert_eq!(text.lines().count(), 2);
        assert!(text.contains(r#""outcome":"allowed_in_haunt""#), "{text}");

        fs::write(&path, format!("{text}not json\n")).unwrap();
        let mut again = DecisionLog::default();
        again.open(&d).unwrap();
        let got: Vec<_> = again.query("", 10).into_iter().map(|x| x.preview).collect();
        assert_eq!(got, ["git push", "before open"], "newest first, bad lines skipped");
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn refuses_a_symlinked_log() {
        let d = dir("link");
        let target = d.join("elsewhere");
        fs::write(&target, b"").unwrap();
        std::os::unix::fs::symlink(&target, d.join(FILE_NAME)).unwrap();
        assert!(DecisionLog::default().open(&d).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"");
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn query_filters_and_limits() {
        let mut log = DecisionLog::default();
        log.record(decision("git push", Outcome::AllowedInHaunt));
        log.record(decision("rm -rf build", Outcome::DeniedInHaunt));
        log.record(decision("git status", Outcome::AnsweredInTerminal));
        let q = |s: &str, n| log.query(s, n).into_iter().map(|x| x.preview).collect::<Vec<_>>();
        assert_eq!(q("GIT", 10), ["git status", "git push"]);
        assert_eq!(q("git", 1), ["git status"]);
        assert_eq!(q("denied", 10), ["rm -rf build"]);
        assert_eq!(q("", 10).len(), 3);
    }
}
