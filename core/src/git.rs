//! Branch lookup for the cwds the UI and the hooks report, cached per surface so an unchanged
//! HEAD costs one lstat, and always done outside the state lock.

use std::collections::HashMap;
use std::fs::{self, Metadata, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::sync::lock;

const MAX_READ: u64 = 4096;

/// Identifies one version of a HEAD file: a checkout rewrites or renames it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    ino: u64,
    size: u64,
    mtime: (i64, i64),
}

impl Stamp {
    fn of(m: &Metadata) -> Self {
        Self { ino: m.ino(), size: m.size(), mtime: (m.mtime(), m.mtime_nsec()) }
    }
}

/// Branch from the nearest `.git` above `path`, or the short hash when detached.
pub fn branch(path: &str) -> Option<String> {
    find(path).map(|(_, _, b)| b)
}

fn find(path: &str) -> Option<(PathBuf, Stamp, String)> {
    let mut dir = Some(Path::new(path));
    while let Some(d) = dir {
        let git = d.join(".git");
        if let Ok(meta) = fs::metadata(&git) {
            let git_dir = if meta.is_dir() {
                git
            } else {
                let (s, _) = read_small(&git)?;
                d.join(s.strip_prefix("gitdir:")?.trim())
            };
            let head_path = git_dir.join("HEAD");
            let (head, stamp) = read_small(&head_path)?;
            let h = head.trim();
            let b = match h.strip_prefix("ref: refs/heads/") {
                Some(b) => b.to_owned(),
                None => h.chars().take(7).collect(),
            };
            return Some((head_path, stamp, b));
        }
        dir = d.parent();
    }
    None
}

/// On a pty-chosen path: never blocks on a FIFO or follows a symlink to /dev/zero.
fn read_small(path: &Path) -> Option<(String, Stamp)> {
    let f = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW).open(path).ok()?;
    let meta = f.metadata().ok()?;
    if !meta.is_file() {
        return None;
    }
    let mut buf = Vec::new();
    f.take(MAX_READ).read_to_end(&mut buf).ok()?;
    Some((String::from_utf8_lossy(&buf).into_owned(), Stamp::of(&meta)))
}

/// The last lookup for one cwd. A hit needs the same cwd and an unchanged HEAD; a cwd outside
/// any repo is walked again each time, so a `git init` shows up.
#[derive(Default)]
struct Cached {
    cwd: String,
    head: Option<(PathBuf, Stamp, String)>,
}

impl Cached {
    fn branch(&mut self, cwd: &str) -> Option<String> {
        if self.cwd == cwd
            && let Some((path, stamp, b)) = &self.head
            && fs::symlink_metadata(path).is_ok_and(|m| Stamp::of(&m) == *stamp)
        {
            return Some(b.clone());
        }
        cwd.clone_into(&mut self.cwd);
        self.head = find(cwd);
        self.head.as_ref().map(|(_, _, b)| b.clone())
    }
}

#[derive(Default)]
struct SurfaceBranches {
    shell: Cached,
    agent: Cached,
    /// The latest verified hook cwd, as `Session::cwd` keeps it.
    agent_cwd: Option<String>,
}

/// Every surface's branch caches. Its own lock, never held with the state lock.
#[derive(Default)]
pub struct Branches(Mutex<HashMap<String, SurfaceBranches>>);

impl Branches {
    /// The branch at the surface cwd the UI reported.
    pub fn shell(&self, surface: &str, cwd: &str) -> Option<String> {
        lock(&self.0).entry(surface.to_owned()).or_default().shell.branch(cwd)
    }

    /// For a verified event: the branch at the agent cwd after it (`event_cwd` if absolute, else
    /// the last one), re-read so a checkout inside the session shows up. None when no cwd is known.
    pub fn agent(&self, surface: &str, event_cwd: Option<&str>) -> Option<Option<String>> {
        let mut all = lock(&self.0);
        let s = all.entry(surface.to_owned()).or_default();
        if let Some(c) = event_cwd.filter(|c| c.starts_with('/')) {
            s.agent_cwd = Some(c.to_owned());
        }
        let cwd = s.agent_cwd.clone()?;
        Some(s.agent.branch(&cwd))
    }

    pub fn forget(&self, surface: &str) {
        lock(&self.0).remove(surface);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    use crate::testdir::TempDir;

    fn temp(name: &str) -> TempDir {
        TempDir::new(name)
    }

    #[test]
    fn finds_branch_above_and_through_gitdir_files() {
        let root = temp("ok");
        fs::create_dir_all(root.join("repo/.git")).unwrap();
        fs::create_dir_all(root.join("repo/sub/deep")).unwrap();
        fs::write(root.join("repo/.git/HEAD"), "ref: refs/heads/feature/x\n").unwrap();
        assert_eq!(branch(root.join("repo/sub/deep").to_str().unwrap()).as_deref(), Some("feature/x"));

        fs::create_dir_all(root.join("wt")).unwrap();
        fs::create_dir_all(root.join("gd")).unwrap();
        fs::write(root.join("wt/.git"), format!("gitdir: {}\n", root.join("gd").display())).unwrap();
        fs::write(root.join("gd/HEAD"), "0123456789abcdef\n").unwrap();
        assert_eq!(branch(root.join("wt").to_str().unwrap()).as_deref(), Some("0123456"));

        fs::create_dir_all(root.join("plain")).unwrap();
        assert_eq!(branch(root.join("plain").to_str().unwrap()), None);
    }

    #[test]
    fn cached_lookups_follow_checkouts_and_cwd_changes() {
        let root = temp("cache");
        fs::create_dir_all(root.join("a/.git")).unwrap();
        fs::create_dir_all(root.join("b/.git")).unwrap();
        fs::write(root.join("a/.git/HEAD"), "ref: refs/heads/main\n").unwrap();
        fs::write(root.join("b/.git/HEAD"), "ref: refs/heads/other\n").unwrap();
        let (a, b) = (root.join("a").to_str().unwrap().to_owned(), root.join("b").to_str().unwrap().to_owned());
        let br = Branches::default();
        assert_eq!(br.agent("s", None), None, "no cwd known yet");
        assert_eq!(br.agent("s", Some(&a)), Some(Some("main".into())));
        assert_eq!(br.agent("s", Some("relative")), Some(Some("main".into())), "only an absolute cwd moves it");
        // Same length, so only the inode or mtime can tell: a checkout renames HEAD into place.
        fs::write(root.join("a/.git/HEAD.lock"), "ref: refs/heads/next\n").unwrap();
        fs::rename(root.join("a/.git/HEAD.lock"), root.join("a/.git/HEAD")).unwrap();
        assert_eq!(br.agent("s", None), Some(Some("next".into())));
        assert_eq!(br.agent("s", Some(&b)), Some(Some("other".into())));
        assert_eq!(br.shell("s", &a), Some("next".into()), "the shell cwd has its own cache");
        br.forget("s");
        assert_eq!(br.agent("s", None), None);
    }

    #[test]
    fn hostile_git_files_are_refused_without_blocking() {
        let root = temp("hostile");
        let at = |p: &str| root.join(p).to_str().unwrap().to_owned();

        fs::create_dir_all(root.join("fifo/.git")).unwrap();
        let c = std::ffi::CString::new(at("fifo/.git/HEAD")).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let t = Instant::now();
        assert_eq!(branch(&at("fifo")), None);
        assert!(t.elapsed() < Duration::from_secs(1));

        fs::create_dir_all(root.join("zero/.git")).unwrap();
        std::os::unix::fs::symlink("/dev/zero", root.join("zero/.git/HEAD")).unwrap();
        assert_eq!(branch(&at("zero")), None);
        fs::create_dir_all(root.join("zerogit")).unwrap();
        std::os::unix::fs::symlink("/dev/zero", root.join("zerogit/.git")).unwrap();
        assert_eq!(branch(&at("zerogit")), None);

        fs::create_dir_all(root.join("big/.git")).unwrap();
        fs::write(root.join("big/.git/HEAD"), format!("ref: refs/heads/{}", "x".repeat(10_000))).unwrap();
        assert_eq!(branch(&at("big")).map(|b| b.len() + 16), Some(MAX_READ as usize));
    }
}
