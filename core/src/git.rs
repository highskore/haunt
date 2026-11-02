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
/// packed-refs is read whole to find HEAD's ref; a bigger file means no turn-start commit.
const MAX_PACKED: u64 = 1 << 20;

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
    let head_path = git_dir(path)?.join("HEAD");
    let (head, stamp) = read_small(&head_path)?;
    let h = head.trim();
    let b = match h.strip_prefix("ref: refs/heads/") {
        Some(b) => b.to_owned(),
        None => h.chars().take(7).collect(),
    };
    Some((head_path, stamp, b))
}

/// The commit HEAD points at above `path`: a loose ref (in the worktree's or the common git dir) or a
/// packed one. None when it can't be read within the size limits, rather than a guess.
pub fn head_commit(path: &str) -> Option<String> {
    let dir = git_dir(path)?;
    let (head, _) = read_small(&dir.join("HEAD"))?;
    let h = head.trim();
    let Some(r) = h.strip_prefix("ref: ") else { return object_id(h) };
    if !r.starts_with("refs/") || r.split('/').any(|c| c.is_empty() || c == "." || c == "..") {
        return None;
    }
    let common = read_small(&dir.join("commondir")).map_or_else(|| dir.clone(), |(c, _)| dir.join(c.trim()));
    for d in [&dir, &common] {
        if let Some((s, _)) = read_small(&d.join(r)) {
            return object_id(s.trim());
        }
    }
    let (packed, _) = read_limited(&common.join("packed-refs"), MAX_PACKED)?;
    packed.lines().find_map(|l| l.strip_suffix(r)?.strip_suffix(' ').and_then(object_id))
}

/// A full SHA-1 or SHA-256 object id.
fn object_id(s: &str) -> Option<String> {
    ((s.len() == 40 || s.len() == 64) && s.bytes().all(|b| b.is_ascii_hexdigit())).then(|| s.to_ascii_lowercase())
}

/// The git dir of the nearest `.git` above `path`, following a worktree's `gitdir:` file.
fn git_dir(path: &str) -> Option<PathBuf> {
    let mut dir = Some(Path::new(path));
    while let Some(d) = dir {
        let git = d.join(".git");
        if let Ok(meta) = fs::metadata(&git) {
            if meta.is_dir() {
                return Some(git);
            }
            let (s, _) = read_small(&git)?;
            return Some(d.join(s.strip_prefix("gitdir:")?.trim()));
        }
        dir = d.parent();
    }
    None
}

/// On a pty-chosen path: never blocks on a FIFO or follows a symlink to /dev/zero.
fn read_small(path: &Path) -> Option<(String, Stamp)> {
    read_limited(path, MAX_READ)
}

fn read_limited(path: &Path, max: u64) -> Option<(String, Stamp)> {
    let f = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW).open(path).ok()?;
    let meta = f.metadata().ok()?;
    if !meta.is_file() {
        return None;
    }
    let mut buf = Vec::new();
    f.take(max).read_to_end(&mut buf).ok()?;
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

    /// Where a turn on the surface runs: the agent cwd if known, else the shell cwd the UI reported.
    pub fn turn_cwd(&self, surface: &str) -> Option<String> {
        let all = lock(&self.0);
        let s = all.get(surface)?;
        s.agent_cwd.clone().or_else(|| (!s.shell.cwd.is_empty()).then(|| s.shell.cwd.clone()))
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
    fn head_commit_follows_loose_packed_and_worktree_refs() {
        let root = temp("head");
        let sha = "0123456789abcdef0123456789abcdef01234567";
        let other = "89abcdef0123456789abcdef0123456789abcdef";
        fs::create_dir_all(root.join("repo/.git/refs/heads")).unwrap();
        fs::write(root.join("repo/.git/HEAD"), "ref: refs/heads/main\n").unwrap();
        fs::write(root.join("repo/.git/refs/heads/main"), format!("{sha}\n")).unwrap();
        let repo = root.join("repo").to_str().unwrap().to_owned();
        assert_eq!(head_commit(&repo).as_deref(), Some(sha));

        fs::remove_file(root.join("repo/.git/refs/heads/main")).unwrap();
        fs::write(root.join("repo/.git/packed-refs"), format!("# pack-refs\n{other} refs/heads/mainline\n{sha} refs/heads/main\n")).unwrap();
        assert_eq!(head_commit(&repo).as_deref(), Some(sha));

        fs::create_dir_all(root.join("repo/.git/worktrees/wt")).unwrap();
        fs::write(root.join("repo/.git/worktrees/wt/HEAD"), "ref: refs/heads/main\n").unwrap();
        fs::write(root.join("repo/.git/worktrees/wt/commondir"), "../..\n").unwrap();
        fs::create_dir_all(root.join("wt")).unwrap();
        fs::write(root.join("wt/.git"), format!("gitdir: {}\n", root.join("repo/.git/worktrees/wt").display())).unwrap();
        assert_eq!(head_commit(root.join("wt").to_str().unwrap()).as_deref(), Some(sha));

        fs::write(root.join("repo/.git/HEAD"), format!("{other}\n")).unwrap();
        assert_eq!(head_commit(&repo).as_deref(), Some(other), "detached");
        fs::write(root.join("repo/.git/HEAD"), "ref: refs/heads/../../../etc/passwd\n").unwrap();
        assert_eq!(head_commit(&repo), None);
        fs::write(root.join("repo/.git/HEAD"), "ref: refs/heads/gone\n").unwrap();
        assert_eq!(head_commit(&repo), None);
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
