//! Branch lookup for the cwds the UI and the hooks report, cached per surface so an unchanged
//! HEAD costs a few lstats, and always done outside the state lock and the cache's own lock.

use std::collections::HashMap;
use std::fs::{self, Metadata, OpenOptions};
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
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
    find(path).map(|h| h.branch)
}

/// What a lookup found, with what a cache hit has to recheck.
struct Head {
    /// The `.git` file or directory, and its stamp: a rewritten `gitdir:` file moves the repo.
    git: PathBuf,
    git_stamp: Stamp,
    path: PathBuf,
    stamp: Stamp,
    branch: String,
}

fn find(path: &str) -> Option<Head> {
    if !local(Path::new(path)) {
        return None;
    }
    let mut dir = Some(Path::new(path));
    while let Some(d) = dir {
        let git = d.join(".git");
        if let Ok(meta) = fs::metadata(&git) {
            let git_stamp = Stamp::of(&meta);
            let git_dir = if meta.is_dir() {
                git.clone()
            } else {
                let (s, _) = read_small(&git)?;
                let to = d.join(s.strip_prefix("gitdir:")?.trim());
                if !local(&to) {
                    return None;
                }
                to
            };
            let head_path = git_dir.join("HEAD");
            let (head, stamp) = read_small(&head_path)?;
            let h = head.trim();
            let b = match h.strip_prefix("ref: refs/heads/") {
                Some(b) => b.to_owned(),
                None => h.chars().take(7).collect(),
            };
            return Some(Head { git, git_stamp, path: head_path, stamp, branch: b });
        }
        dir = d.parent();
    }
    None
}

/// Whether `path` is on a local filesystem, by the kernel's mount table read with MNT_NOWAIT, so
/// no filesystem is asked: any stat on a dead network or automounted one can hang. Paths are taken
/// as given; a symlink into such a mount is not seen.
#[cfg(target_vendor = "apple")]
fn local(path: &Path) -> bool {
    let size = size_of::<libc::statfs>();
    // SAFETY: a null buffer only asks for the count.
    let n = unsafe { libc::getfsstat(std::ptr::null_mut(), 0, libc::MNT_NOWAIT) };
    if n <= 0 {
        return false;
    }
    // A few spare entries in case a mount appears between the calls.
    let mut buf: Vec<libc::statfs> = Vec::with_capacity(n as usize + 4);
    // SAFETY: the buffer has room for `capacity` entries, and that many bytes' worth is passed.
    let got = unsafe { libc::getfsstat(buf.as_mut_ptr(), (buf.capacity() * size) as libc::c_int, libc::MNT_NOWAIT) };
    if got < 0 {
        return false;
    }
    // SAFETY: getfsstat filled the first `got` entries.
    unsafe { buf.set_len(got as usize) };
    let mounts = buf.iter().map(|m| {
        // SAFETY: f_mntonname is a NUL-terminated path inside its fixed array.
        (unsafe { std::ffi::CStr::from_ptr(m.f_mntonname.as_ptr()) }.to_bytes(), m.f_flags)
    });
    mount_flags(path.as_os_str().as_bytes(), mounts)
        .is_some_and(|f| f & libc::MNT_LOCAL as u32 != 0 && f & libc::MNT_AUTOMOUNTED as u32 == 0)
}

#[cfg(not(target_vendor = "apple"))]
fn local(_: &Path) -> bool {
    true
}

/// The flags of the innermost mount holding `path`.
fn mount_flags<'a>(path: &[u8], mounts: impl Iterator<Item = (&'a [u8], u32)>) -> Option<u32> {
    let under = |on: &[u8]| on == b"/" || path.strip_prefix(on).is_some_and(|rest| rest.first().is_none_or(|&b| b == b'/'));
    mounts.filter(|(on, _)| under(on)).max_by_key(|(on, _)| on.len()).map(|(_, f)| f)
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

/// The last lookup for one cwd. A hit needs the same cwd, the same `.git` and an unchanged HEAD,
/// and no `.git` in the cwd itself if the repo was found above it. A cwd outside any repo is walked
/// again each time, so a `git init` shows up; one on a non-local filesystem never is.
#[derive(Default)]
struct Cached {
    cwd: String,
    head: Option<Head>,
    remote: bool,
}

impl Cached {
    fn branch(&mut self, cwd: &str) -> Option<String> {
        if self.cwd == cwd && self.remote {
            return None;
        }
        if self.cwd == cwd
            && let Some(h) = &self.head
            && fs::symlink_metadata(&h.path).is_ok_and(|m| Stamp::of(&m) == h.stamp)
            && fs::metadata(&h.git).is_ok_and(|m| Stamp::of(&m) == h.git_stamp)
            && (h.git.parent() == Some(Path::new(cwd)) || fs::symlink_metadata(Path::new(cwd).join(".git")).is_err())
        {
            return Some(h.branch.clone());
        }
        cwd.clone_into(&mut self.cwd);
        self.remote = !local(Path::new(cwd));
        self.head = if self.remote { None } else { find(cwd) };
        self.head.as_ref().map(|h| h.branch.clone())
    }
}

#[derive(Default)]
struct SurfaceBranches {
    shell: Cached,
    agent: Cached,
    /// The latest verified hook cwd, as `Session::cwd` keeps it.
    agent_cwd: Option<String>,
}

/// Every surface's branch caches. Its own lock, never held with the state lock nor during a lookup:
/// the UI thread looks up too, and must never wait on another surface's slow filesystem.
#[derive(Default)]
pub struct Branches(Mutex<HashMap<String, SurfaceBranches>>);

impl Branches {
    /// The branch at the surface cwd the UI reported.
    pub fn shell(&self, surface: &str, cwd: &str) -> Option<String> {
        let mut c = std::mem::take(&mut lock(&self.0).entry(surface.to_owned()).or_default().shell);
        let b = c.branch(cwd);
        self.put_back(surface, |s| s.shell = c);
        b
    }

    /// For a verified event: the branch at the agent cwd after it (`event_cwd` if absolute, else
    /// the last one), re-read so a checkout inside the session shows up. None when no cwd is known.
    pub fn agent(&self, surface: &str, event_cwd: Option<&str>) -> Option<Option<String>> {
        let (mut c, cwd) = {
            let mut all = lock(&self.0);
            let s = all.entry(surface.to_owned()).or_default();
            if let Some(c) = event_cwd.filter(|c| c.starts_with('/')) {
                s.agent_cwd = Some(c.to_owned());
            }
            (std::mem::take(&mut s.agent), s.agent_cwd.clone()?)
        };
        let b = c.branch(&cwd);
        self.put_back(surface, |s| s.agent = c);
        Some(b)
    }

    /// Stores a cache taken out for a lookup, unless the surface was forgotten meanwhile. A lookup
    /// running alongside for the same surface found it empty, which only costs it a walk.
    fn put_back(&self, surface: &str, f: impl FnOnce(&mut SurfaceBranches)) {
        if let Some(s) = lock(&self.0).get_mut(surface) {
            f(s);
        }
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

        fs::create_dir_all(root.join("a/sub")).unwrap();
        let sub = root.join("a/sub").to_str().unwrap().to_owned();
        assert_eq!(br.shell("s", &sub), Some("next".into()));
        fs::create_dir_all(root.join("a/sub/.git")).unwrap();
        fs::write(root.join("a/sub/.git/HEAD"), "ref: refs/heads/inner\n").unwrap();
        assert_eq!(br.shell("s", &sub), Some("inner".into()), "a repo made in the cwd itself shows up");

        fs::create_dir_all(root.join("wt")).unwrap();
        let wt = root.join("wt").to_str().unwrap().to_owned();
        fs::write(root.join("wt/.git"), format!("gitdir: {}\n", root.join("a/.git").display())).unwrap();
        assert_eq!(br.shell("s", &wt), Some("next".into()));
        fs::write(root.join("wt/.git"), format!("gitdir: {}\n", root.join("b/.git").display())).unwrap();
        assert_eq!(br.shell("s", &wt), Some("other".into()), "a rewritten gitdir file moves the repo");
        br.forget("s");
        assert_eq!(br.agent("s", None), None);
    }

    #[test]
    fn only_local_mounts_are_looked_up() {
        let mounts = [(&b"/"[..], 0x1000), (b"/Volumes/nfs", 0), (b"/Volumes/nfs/inner", 0x1000), (b"/Vol", 0)];
        let at = |p: &str| mount_flags(p.as_bytes(), mounts.iter().copied());
        assert_eq!(at("/Users/me"), Some(0x1000));
        assert_eq!(at("/Volumes/nfs"), Some(0));
        assert_eq!(at("/Volumes/nfs/x"), Some(0));
        assert_eq!(at("/Volumes/nfs/inner/x"), Some(0x1000), "the innermost mount wins");
        assert_eq!(at("/Volumes/nfsx"), Some(0x1000), "a mount is a whole path component");
        assert!(local(Path::new("/")) && local(&std::env::temp_dir()));
        #[cfg(target_vendor = "apple")]
        {
            assert!(!local(Path::new("/System/Volumes/Data/home/x")), "macOS automounts home there");
            let mut c = Cached::default();
            assert_eq!(c.branch("/System/Volumes/Data/home/x"), None);
            assert!(c.remote, "remembered, so the next event asks nothing");
        }
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
