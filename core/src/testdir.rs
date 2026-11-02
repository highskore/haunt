//! Test scratch paths that clean up after themselves, even when the test panics.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

/// A fresh path under /tmp, not created; removed with everything under it on drop. /tmp, not
/// `temp_dir()`, because a socket path must fit macOS's 104-byte `sun_path`.
pub(crate) struct TempDir(PathBuf);

impl TempDir {
    pub(crate) fn new(tag: &str) -> Self {
        static N: AtomicU32 = AtomicU32::new(0);
        let p = PathBuf::from(format!("/tmp/h-{tag}-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        remove(&p);
        Self(p)
    }

    /// Created, and canonical: /tmp is a symlink on macOS.
    pub(crate) fn created(tag: &str) -> Self {
        let mut d = Self::new(tag);
        std::fs::create_dir_all(&d.0).unwrap();
        d.0 = std::fs::canonicalize(&d.0).unwrap();
        d
    }
}

fn remove(p: &Path) {
    if std::fs::remove_dir_all(p).is_err() {
        let _ = std::fs::remove_file(p);
    }
}

impl std::ops::Deref for TempDir {
    type Target = Path;
    fn deref(&self) -> &Path {
        &self.0
    }
}

impl AsRef<Path> for TempDir {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        remove(&self.0);
    }
}
