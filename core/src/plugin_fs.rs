//! `fs` import: paths are canonicalised and matched against the manifest globs, and every
//! component is opened with `O_NOFOLLOW`, so a symlink can't lead a plugin outside its grant.

use std::ffi::CString;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};

pub const FILE_CAP: usize = 4 << 20;
const MAX_CWDS: usize = 256;
const CWD: &str = "${cwd}";

/// Globs are absolute or start with `${cwd}/`; `*` and `?` match within one path segment.
pub fn validate_glob(g: &str) -> Result<(), String> {
    let rest = g.strip_prefix(CWD).unwrap_or(g);
    if !rest.starts_with('/') {
        return Err(format!("fs glob {g:?} must be absolute or start with ${{cwd}}/"));
    }
    if rest.contains(CWD) || rest.contains("**") {
        return Err(format!("fs glob {g:?}: ${{cwd}} only at the start, and no **"));
    }
    if rest.split('/').any(|s| s == ".." || s == ".") {
        return Err(format!("fs glob {g:?} must not contain . or .."));
    }
    Ok(())
}

fn seg_match(pat: &[u8], s: &[u8]) -> bool {
    match (pat.first(), s.first()) {
        (None, None) => true,
        (Some(b'*'), _) => seg_match(&pat[1..], s) || (!s.is_empty() && seg_match(pat, &s[1..])),
        (Some(b'?'), Some(_)) => seg_match(&pat[1..], &s[1..]),
        (Some(p), Some(c)) if p == c => seg_match(&pat[1..], &s[1..]),
        _ => false,
    }
}

fn segments(p: &Path) -> Vec<Vec<u8>> {
    p.components().filter_map(|c| if let Component::Normal(s) = c { Some(s.as_bytes().to_vec()) } else { None }).collect()
}

/// Only the cwd base is canonical; a literal glob segment that is a symlink must not move the grant.
fn pattern(base: &Path, rest: &str) -> Vec<Vec<u8>> {
    let mut pat = segments(base);
    pat.extend(rest.split('/').filter(|s| !s.is_empty()).map(|s| s.as_bytes().to_vec()));
    pat
}

#[derive(Debug, Default)]
pub struct FsScope {
    read: Vec<String>,
    write: Vec<String>,
    cwds: Vec<PathBuf>,
}

impl FsScope {
    pub fn new(read: &[String], write: &[String]) -> Self {
        Self { read: read.to_vec(), write: write.to_vec(), cwds: Vec::new() }
    }

    /// `${cwd}` expands to the cwd of agents the plugin has seen events for.
    pub fn add_cwd(&mut self, cwd: &str) {
        if let Ok(c) = Path::new(cwd).canonicalize()
            && !self.cwds.contains(&c)
            && self.cwds.len() < MAX_CWDS
        {
            self.cwds.push(c);
        }
    }

    fn patterns(&self, globs: &[String]) -> Vec<Vec<Vec<u8>>> {
        let mut out = Vec::new();
        for g in globs {
            if let Some(rest) = g.strip_prefix(CWD) {
                out.extend(self.cwds.iter().map(|c| pattern(c, rest)));
            } else {
                out.push(pattern(Path::new("/"), g));
            }
        }
        out
    }

    fn allowed(&self, globs: &[String], path: &Path) -> bool {
        let segs = segments(path);
        self.patterns(globs).iter().any(|p| p.len() == segs.len() && p.iter().zip(&segs).all(|(p, s)| seg_match(p, s)))
    }

    pub fn read(&self, path: &str) -> Result<Vec<u8>, String> {
        let (dir, name, full) = resolve(path)?;
        if !self.allowed(&self.read, &full) {
            return Err(denied(path));
        }
        let fd = open_at(&dir, &name, libc::O_RDONLY | libc::O_NOFOLLOW, 0).map_err(|e| io_err(path, e))?;
        let mut f = std::fs::File::from(fd);
        if !f.metadata().map_err(|e| io_err(path, e))?.is_file() {
            return Err(format!("{path}: not a regular file"));
        }
        let mut buf = Vec::new();
        Read::by_ref(&mut f).take(FILE_CAP as u64 + 1).read_to_end(&mut buf).map_err(|e| io_err(path, e))?;
        if buf.len() > FILE_CAP {
            return Err(format!("{path}: larger than {FILE_CAP} bytes"));
        }
        Ok(buf)
    }

    /// Writes a temp file next to the target and renames it over; a symlinked target is refused.
    pub fn write(&self, path: &str, data: &[u8]) -> Result<(), String> {
        if data.len() > FILE_CAP {
            return Err(format!("{path}: larger than {FILE_CAP} bytes"));
        }
        let (dir, name, full) = resolve(path)?;
        if !self.allowed(&self.write, &full) {
            return Err(denied(path));
        }
        let mode = match stat_at(&dir, &name) {
            Ok(st) if st.st_mode & libc::S_IFMT == libc::S_IFLNK => return Err(format!("{path}: is a symlink")),
            Ok(st) if st.st_mode & libc::S_IFMT != libc::S_IFREG => return Err(format!("{path}: not a regular file")),
            Ok(st) => st.st_mode & 0o7777,
            Err(_) => 0o600,
        };
        let mut nonce = [0u8; 8];
        getrandom::fill(&mut nonce).map_err(|e| e.to_string())?;
        let tmp = CString::new(format!(".{}.{:x}.tmp", name.to_string_lossy(), u64::from_le_bytes(nonce))).map_err(|e| e.to_string())?;
        let flags = libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW;
        let fd = open_at(&dir, &tmp, flags, 0o600).map_err(|e| io_err(path, e))?;
        let res = (|| {
            if unsafe { libc::fchmod(fd.as_raw_fd(), mode as libc::mode_t) } != 0 {
                return Err(io::Error::last_os_error());
            }
            let mut f = std::fs::File::from(fd);
            f.write_all(data)?;
            f.sync_all()?;
            if unsafe { libc::renameat(dir.as_raw_fd(), tmp.as_ptr(), dir.as_raw_fd(), name.as_ptr()) } != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        })();
        if res.is_err() {
            unsafe { libc::unlinkat(dir.as_raw_fd(), tmp.as_ptr(), 0) };
        }
        res.map_err(|e| io_err(path, e))
    }

    /// Entry names under `path` that themselves match a read glob.
    pub fn list(&self, path: &str) -> Result<Vec<String>, String> {
        let full = canonical(path)?;
        open_dir_nofollow(&full).map_err(|e| io_err(path, e))?;
        let depth = segments(&full).len() + 1;
        if !self.patterns(&self.read).iter().any(|p| p.len() == depth) {
            return Err(denied(path));
        }
        let mut out = Vec::new();
        for e in std::fs::read_dir(&full).map_err(|e| io_err(path, e))? {
            let e = e.map_err(|e| io_err(path, e))?;
            if self.allowed(&self.read, &full.join(e.file_name())) {
                out.push(e.file_name().to_string_lossy().into_owned());
            }
        }
        out.sort();
        Ok(out)
    }
}

fn denied(path: &str) -> String {
    format!("{path}: not covered by this plugin's fs grant")
}

fn io_err(path: &str, e: io::Error) -> String {
    format!("{path}: {e}")
}

fn canonical(path: &str) -> Result<PathBuf, String> {
    let p = Path::new(path);
    if !p.is_absolute() || p.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(format!("{path}: must be absolute without .."));
    }
    p.canonicalize().map_err(|e| io_err(path, e))
}

/// The opened canonical parent, the final name, and the canonical full path.
fn resolve(path: &str) -> Result<(OwnedFd, CString, PathBuf), String> {
    let p = Path::new(path);
    let name = match p.components().next_back() {
        Some(Component::Normal(n)) => n.to_owned(),
        _ => return Err(format!("{path}: not a file path")),
    };
    let parent = canonical(p.parent().and_then(|d| d.to_str()).ok_or_else(|| format!("{path}: no parent"))?)?;
    let dir = open_dir_nofollow(&parent).map_err(|e| io_err(path, e))?;
    let c = CString::new(name.as_bytes()).map_err(|e| e.to_string())?;
    Ok((dir, c, parent.join(name)))
}

/// Opens `path` one component at a time with `O_NOFOLLOW`, so a symlink swapped in after
/// canonicalisation fails instead of being followed.
fn open_dir_nofollow(path: &Path) -> io::Result<OwnedFd> {
    let root = CString::new("/").expect("no nul");
    let mut fd = unsafe { libc::open(root.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut cur = unsafe { OwnedFd::from_raw_fd(fd) };
    for seg in segments(path) {
        let c = CString::new(seg).map_err(io::Error::other)?;
        fd = unsafe { libc::openat(cur.as_raw_fd(), c.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        cur = unsafe { OwnedFd::from_raw_fd(fd) };
    }
    Ok(cur)
}

fn open_at(dir: &OwnedFd, name: &CString, flags: i32, mode: libc::c_uint) -> io::Result<OwnedFd> {
    let fd = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags | libc::O_CLOEXEC, mode) };
    if fd < 0 { Err(io::Error::last_os_error()) } else { Ok(unsafe { OwnedFd::from_raw_fd(fd) }) }
}

fn stat_at(dir: &OwnedFd, name: &CString) -> io::Result<libc::stat> {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstatat(dir.as_raw_fd(), name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(st)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn tempdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("haunt-fs-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("proj/.claude")).unwrap();
        d.canonicalize().unwrap()
    }

    fn scope(root: &Path) -> FsScope {
        let mut s = FsScope::new(&["${cwd}/.claude/*.json".into()], &["${cwd}/.claude/settings.local.json".into()]);
        s.add_cwd(root.join("proj").to_str().unwrap());
        s
    }

    #[test]
    fn globs_are_validated() {
        assert!(validate_glob("${cwd}/.claude/settings.json").is_ok());
        assert!(validate_glob("/etc/hosts").is_ok());
        assert!(validate_glob(".claude/x").is_err());
        assert!(validate_glob("${cwd}/../x").is_err());
        assert!(validate_glob("${cwd}/**/x").is_err());
        assert!(validate_glob("/a/${cwd}/x").is_err());
    }

    #[test]
    fn reads_and_writes_inside_the_grant_only() {
        let root = tempdir("rw");
        let s = scope(&root);
        let file = root.join("proj/.claude/settings.local.json");
        let path = file.to_str().unwrap();
        s.write(path, b"{}").unwrap();
        assert_eq!(s.read(path).unwrap(), b"{}");
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(s.list(root.join("proj/.claude").to_str().unwrap()).unwrap(), vec!["settings.local.json"]);

        std::fs::write(root.join("proj/secret.txt"), "x").unwrap();
        assert!(s.read(root.join("proj/secret.txt").to_str().unwrap()).is_err());
        assert!(s.write(root.join("proj/.claude/settings.json").to_str().unwrap(), b"x").is_err(), "read-only glob");
        assert!(s.read(&format!("{}/proj/.claude/../secret.txt", root.display())).is_err());
        assert!(s.list(root.join("proj").to_str().unwrap()).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn symlinks_are_not_followed() {
        let root = tempdir("link");
        let s = scope(&root);
        std::fs::write(root.join("outside.json"), "secret").unwrap();
        let link = root.join("proj/.claude/settings.local.json");
        symlink(root.join("outside.json"), &link).unwrap();
        assert!(s.read(link.to_str().unwrap()).is_err());
        assert!(s.write(link.to_str().unwrap(), b"pwned").unwrap_err().contains("symlink"));
        assert_eq!(std::fs::read(root.join("outside.json")).unwrap(), b"secret");

        // A symlinked directory resolves outside the cwd, so the canonical path no longer matches.
        std::fs::create_dir_all(root.join("elsewhere")).unwrap();
        std::fs::write(root.join("elsewhere/x.json"), "secret").unwrap();
        std::fs::remove_dir_all(root.join("proj/.claude")).unwrap();
        symlink(root.join("elsewhere"), root.join("proj/.claude")).unwrap();
        assert!(s.read(root.join("proj/.claude/x.json").to_str().unwrap()).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn no_cwd_seen_means_no_access() {
        let root = tempdir("nocwd");
        let s = FsScope::new(&["${cwd}/.claude/*.json".into()], &[]);
        std::fs::write(root.join("proj/.claude/a.json"), "x").unwrap();
        assert!(s.read(root.join("proj/.claude/a.json").to_str().unwrap()).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
