//! Branch lookup for the cwd agent hooks report, mirroring the UI's `Git.branch`.

use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

const MAX_READ: u64 = 4096;
/// packed-refs is read whole to find HEAD's ref; a bigger file means no turn-start commit.
const MAX_PACKED: u64 = 1 << 20;

/// Branch from the nearest `.git` above `path`, or the short hash when detached.
pub fn branch(path: &str) -> Option<String> {
    let head = read_small(&git_dir(path)?.join("HEAD"))?;
    let h = head.trim();
    Some(match h.strip_prefix("ref: refs/heads/") {
        Some(b) => b.to_owned(),
        None => h.chars().take(7).collect(),
    })
}

/// The commit HEAD points at above `path`: a loose ref (in the worktree's or the common git dir) or a
/// packed one. None when it can't be read within the size limits, rather than a guess.
pub fn head_commit(path: &str) -> Option<String> {
    let dir = git_dir(path)?;
    let head = read_small(&dir.join("HEAD"))?;
    let h = head.trim();
    let Some(r) = h.strip_prefix("ref: ") else { return object_id(h) };
    if !r.starts_with("refs/") || r.split('/').any(|c| c.is_empty() || c == "." || c == "..") {
        return None;
    }
    let common = read_small(&dir.join("commondir")).map_or_else(|| dir.clone(), |c| dir.join(c.trim()));
    for d in [&dir, &common] {
        if let Some(s) = read_small(&d.join(r)) {
            return object_id(s.trim());
        }
    }
    let packed = read_limited(&common.join("packed-refs"), MAX_PACKED)?;
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
            let s = read_small(&git)?;
            return Some(d.join(s.strip_prefix("gitdir:")?.trim()));
        }
        dir = d.parent();
    }
    None
}

/// Runs under the state lock on a hook-chosen path: never blocks on a FIFO or follows a symlink to /dev/zero.
fn read_small(path: &Path) -> Option<String> {
    read_limited(path, MAX_READ)
}

fn read_limited(path: &Path, max: u64) -> Option<String> {
    let f = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW).open(path).ok()?;
    if !f.metadata().ok()?.is_file() {
        return None;
    }
    let mut buf = Vec::new();
    f.take(max).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn temp(name: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("haunt-git-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        root
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
        let _ = fs::remove_dir_all(&root);
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
        let _ = fs::remove_dir_all(&root);
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
        let _ = fs::remove_dir_all(&root);
    }
}
