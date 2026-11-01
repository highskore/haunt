//! Branch lookup for the cwd agent hooks report, mirroring the UI's `Git.branch`.

use std::fs;
use std::path::Path;

/// Branch from the nearest `.git` above `path`, or the short hash when detached.
pub fn branch(path: &str) -> Option<String> {
    let mut dir = Some(Path::new(path));
    while let Some(d) = dir {
        let git = d.join(".git");
        if let Ok(meta) = fs::metadata(&git) {
            let git_dir = if meta.is_dir() {
                git
            } else {
                let s = fs::read_to_string(&git).ok()?;
                d.join(s.strip_prefix("gitdir:")?.trim())
            };
            let head = fs::read_to_string(git_dir.join("HEAD")).ok()?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_branch_above_and_through_gitdir_files() {
        let root = std::env::temp_dir().join(format!("haunt-git-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
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
}
