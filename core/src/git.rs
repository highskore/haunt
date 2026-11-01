//! Branch lookup for the cwd agent hooks report, mirroring the UI's `Git.branch`.

use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

const MAX_READ: u64 = 4096;

/// Branch from the nearest `.git` above `path`, or the short hash when detached.
pub fn branch(path: &str) -> Option<String> {
    let mut dir = Some(Path::new(path));
    while let Some(d) = dir {
        let git = d.join(".git");
        if let Ok(meta) = fs::metadata(&git) {
            let git_dir = if meta.is_dir() {
                git
            } else {
                let s = read_small(&git)?;
                d.join(s.strip_prefix("gitdir:")?.trim())
            };
            let head = read_small(&git_dir.join("HEAD"))?;
            let h = head.trim();
            return Some(match h.strip_prefix("ref: refs/heads/") {
                Some(b) => b.to_owned(),
                None => h.chars().take(7).collect(),
            });
        }
        dir = d.parent();
    }
    None
}

/// Runs under the state lock on a hook-chosen path: never blocks on a FIFO or follows a symlink to /dev/zero.
fn read_small(path: &Path) -> Option<String> {
    let f = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW).open(path).ok()?;
    if !f.metadata().ok()?.is_file() {
        return None;
    }
    let mut buf = Vec::new();
    f.take(MAX_READ).read_to_end(&mut buf).ok()?;
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
