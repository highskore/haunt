//! `fs` import: paths are canonicalised and matched against the manifest globs, and every
//! component is opened with `O_NOFOLLOW`, so a symlink can't lead a plugin outside its grant.

use std::ffi::CString;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};

pub const FILE_CAP: usize = 4 << 20;
/// Names `list` returns, and entries it looks at, at most; it runs on the host, outside the CPU budget.
pub const LIST_CAP: usize = 4096;
const LIST_SCAN: usize = 65_536;
const MAX_CWDS: usize = 256;
const CWD: &str = "${cwd}";
const GLOB_CAP: usize = 256;
const STAR_CAP: usize = 8;
const PATH_CAP: usize = libc::PATH_MAX as usize;

/// Globs are absolute or start with `${cwd}/`; `*` and `?` match within one path segment.
pub fn validate_glob(g: &str) -> Result<(), String> {
    if g.len() > GLOB_CAP || g.matches('*').count() > STAR_CAP {
        return Err(format!("fs glob {g:?}: at most {GLOB_CAP} bytes and {STAR_CAP} '*'"));
    }
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

/// Iterative wildcard match, O(len(pat) * len(s)): it runs on the host, outside the CPU budget.
fn seg_match(pat: &[u8], s: &[u8]) -> bool {
    let (mut p, mut i) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while i < s.len() {
        if p < pat.len() && pat[p] == b'*' {
            while p < pat.len() && pat[p] == b'*' {
                p += 1;
            }
            star = Some((p, i));
        } else if p < pat.len() && (pat[p] == b'?' || pat[p] == s[i]) {
            p += 1;
            i += 1;
        } else if let Some((sp, si)) = star {
            p = sp;
            i = si + 1;
            star = Some((sp, si + 1));
        } else {
            return false;
        }
    }
    pat[p..].iter().all(|&c| c == b'*')
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
    /// Canonical `$HOME`: `${cwd}` may never be it or one of its ancestors. Unknown means no `${cwd}`.
    home: Option<PathBuf>,
    /// Canonical haunt dir: no path inside it is ever readable or writable, and `${cwd}` may
    /// neither be inside it nor contain it.
    haunt: PathBuf,
}

impl FsScope {
    /// Globs that fail `validate_glob` are dropped, so a hand-edited lockfile can't bypass the caps.
    /// `haunt_dir` defaults to `~/.haunt`.
    pub fn new(read: &[String], write: &[String], haunt_dir: Option<&Path>) -> Self {
        let valid = |gs: &[String]| gs.iter().filter(|g| validate_glob(g).is_ok()).cloned().collect();
        let home = std::env::var_os("HOME").and_then(|h| Path::new(&h).canonicalize().ok());
        let haunt = haunt_dir.map_or_else(crate::model::default_home, Path::to_owned);
        let haunt = haunt.canonicalize().unwrap_or(haunt);
        Self { read: valid(read), write: valid(write), cwds: Vec::new(), home, haunt }
    }

    /// `${cwd}` expands to the folders of tabs the plugin has seen verified agent events in. Only a
    /// folder strictly inside `$HOME` counts, and not one under a dot-folder or `~/Library`, inside
    /// the haunt dir or containing it: those hold keys, app data or haunt's own lockfile. Without a
    /// known `$HOME` nothing is added.
    pub fn add_cwd(&mut self, cwd: &str) {
        let Some(c) = self.project_folder(cwd) else { return };
        if !self.cwds.contains(&c) && self.cwds.len() < MAX_CWDS {
            self.cwds.push(c);
        }
    }

    /// `cwd`, canonical, if it may be a `${cwd}` (see `add_cwd`); `exec` runs only in such a folder.
    pub fn project_folder(&self, cwd: &str) -> Option<PathBuf> {
        let home = self.home.as_ref()?;
        let c = Path::new(cwd).canonicalize().ok()?;
        let rel = c.strip_prefix(home).ok().filter(|r| r.components().next().is_some())?;
        let private = rel.components().any(|p| p.as_os_str().as_bytes().starts_with(b".")) || rel.starts_with("Library");
        let haunt = c.starts_with(&self.haunt) || self.haunt.starts_with(&c);
        (!private && !haunt).then_some(c)
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

    /// `path` is canonical; nothing in the haunt dir is ever allowed, whatever the globs say.
    fn allowed(&self, globs: &[String], path: &Path) -> bool {
        if path.starts_with(&self.haunt) {
            return false;
        }
        let segs = segments(path);
        self.patterns(globs).iter().any(|p| p.len() == segs.len() && p.iter().zip(&segs).all(|(p, s)| seg_match(p, s)))
    }

    pub fn read(&self, path: &str) -> Result<Vec<u8>, String> {
        let (dir, name, full) = resolve(path)?;
        if !self.allowed(&self.read, &full) {
            return Err(denied(path));
        }
        // O_NONBLOCK so a FIFO can't block the host before the regular-file check.
        let fd = open_at(&dir, &name, libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK, 0).map_err(|e| io_err(path, e))?;
        let mut f = std::fs::File::from(fd);
        if !f.metadata().map_err(|e| io_err(path, e))?.is_file() {
            return Err(format!("{path}: not a regular file"));
        }
        if unsafe { libc::fcntl(f.as_raw_fd(), libc::F_SETFL, 0) } != 0 {
            return Err(io_err(path, io::Error::last_os_error()));
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
        if full.starts_with(&self.haunt) {
            return Err(denied(path));
        }
        open_dir_nofollow(&full).map_err(|e| io_err(path, e))?;
        let depth = segments(&full).len() + 1;
        if !self.patterns(&self.read).iter().any(|p| p.len() == depth) {
            return Err(denied(path));
        }
        let mut out = Vec::new();
        for (i, e) in std::fs::read_dir(&full).map_err(|e| io_err(path, e))?.enumerate() {
            if i == LIST_SCAN {
                return Err(format!("{path}: more than {LIST_SCAN} entries"));
            }
            let e = e.map_err(|e| io_err(path, e))?;
            if self.allowed(&self.read, &full.join(e.file_name())) {
                if out.len() == LIST_CAP {
                    return Err(format!("{path}: more than {LIST_CAP} matching entries"));
                }
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
    if path.len() > PATH_CAP {
        return Err(format!("path longer than {PATH_CAP} bytes"));
    }
    let p = Path::new(path);
    if !p.is_absolute() || p.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(format!("{path}: must be absolute without .."));
    }
    p.canonicalize().map_err(|e| io_err(path, e))
}

/// The opened canonical parent, the final name, and the canonical full path.
fn resolve(path: &str) -> Result<(OwnedFd, CString, PathBuf), String> {
    if path.len() > PATH_CAP {
        return Err(format!("path longer than {PATH_CAP} bytes"));
    }
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
    use crate::testdir::TempDir;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn tempdir(tag: &str) -> TempDir {
        let d = TempDir::created(&format!("fs-{tag}"));
        std::fs::create_dir_all(d.join("proj/.claude")).unwrap();
        d
    }

    fn scope(root: &Path) -> FsScope {
        let mut s = FsScope::new(&["${cwd}/.claude/*.json".into()], &["${cwd}/.claude/settings.local.json".into()], None);
        s.home = Some(root.canonicalize().unwrap());
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
    fn matcher_is_correct_and_linear() {
        for (p, s, m) in [("*.json", "a.json", true), ("*.json", "a.jsonx", false), ("a?c", "abc", true), ("a**c", "ac", true), ("", "", true), ("*", "", true), ("x*", "", false), ("*a*b", "zzazb", true), ("*a*b", "zzab_", false)] {
            assert_eq!(seg_match(p.as_bytes(), s.as_bytes()), m, "{p} vs {s}");
        }
        let pat = "*a".repeat(8) + "b";
        let s = "a".repeat(4096);
        let t = std::time::Instant::now();
        assert!(!seg_match(pat.as_bytes(), s.as_bytes()));
        assert!(t.elapsed() < std::time::Duration::from_millis(50), "{:?}", t.elapsed());
        let mut pat = "*a".repeat(200);
        pat.push('b');
        let t = std::time::Instant::now();
        assert!(!seg_match(pat.as_bytes(), s.as_bytes()), "uncapped pattern still finishes");
        assert!(t.elapsed() < std::time::Duration::from_millis(200), "{:?}", t.elapsed());
    }

    #[test]
    fn glob_and_path_lengths_are_capped() {
        assert!(validate_glob(&format!("${{cwd}}/{}", "*a".repeat(9))).is_err());
        assert!(validate_glob(&format!("/{}", "a".repeat(300))).is_err());
        let s = FsScope::new(&[format!("/{}", "*a".repeat(20))], &[], None);
        assert!(s.read.is_empty(), "invalid granted glob dropped");
        assert!(s.read(&format!("/{}", "a".repeat(PATH_CAP + 1))).unwrap_err().contains("longer than"));
    }

    #[test]
    fn fifo_is_refused_without_blocking() {
        let root = tempdir("fifo");
        let fifo = root.join("proj/.claude/settings.local.json");
        let c = CString::new(fifo.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let s = scope(&root);
        let (tx, rx) = std::sync::mpsc::channel();
        let path = fifo.to_str().unwrap().to_owned();
        std::thread::spawn(move || {
            let _ = tx.send((s.read(&path), s.write(&path, b"x")));
        });
        let (r, w) = rx.recv_timeout(std::time::Duration::from_secs(2)).expect("fs on a FIFO must not block");
        assert!(r.unwrap_err().contains("not a regular file"));
        assert!(w.unwrap_err().contains("not a regular file"));
    }

    #[test]
    fn list_is_capped() {
        let root = tempdir("list-cap");
        let dir = root.join("proj/.claude");
        for i in 0..=LIST_CAP {
            std::fs::write(dir.join(format!("{i}.json")), "").unwrap();
        }
        let e = scope(&root).list(dir.to_str().unwrap()).unwrap_err();
        assert!(e.contains("more than 4096 matching entries"), "{e}");
        std::fs::remove_file(dir.join("0.json")).unwrap();
        assert_eq!(scope(&root).list(dir.to_str().unwrap()).unwrap().len(), LIST_CAP);
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
    }

    #[test]
    fn no_cwd_seen_means_no_access() {
        let root = tempdir("nocwd");
        let s = FsScope::new(&["${cwd}/.claude/*.json".into()], &[], None);
        std::fs::write(root.join("proj/.claude/a.json"), "x").unwrap();
        assert!(s.read(root.join("proj/.claude/a.json").to_str().unwrap()).is_err());
    }

    #[test]
    fn cwd_is_a_project_folder_inside_home_and_never_private_or_the_haunt_dir() {
        let root = tempdir("wide");
        let home = root.join("Users/me");
        std::fs::create_dir_all(home.join("code/p")).unwrap();
        std::fs::create_dir_all(home.join(".haunt/plugins")).unwrap();
        let mut s = FsScope::new(&["${cwd}/*".into()], &[], Some(&home.join(".haunt")));
        s.home = Some(home.canonicalize().unwrap());
        for private in [".ssh", ".config/gh", "Library", "Library/Application Support", "code/p/.git"] {
            std::fs::create_dir_all(home.join(private)).unwrap();
        }
        for wide in [home.clone(), root.join("Users"), root.to_path_buf(), PathBuf::from("/"), home.join(".haunt"), home.join(".haunt/plugins")] {
            s.add_cwd(wide.to_str().unwrap());
        }
        for private in [".ssh", ".config/gh", "Library", "Library/Application Support", "code/p/.git"] {
            s.add_cwd(home.join(private).to_str().unwrap());
        }
        s.add_cwd(std::env::temp_dir().to_str().unwrap());
        s.add_cwd(&format!("{}/code/..", home.display()));
        assert!(s.cwds.is_empty(), "{:?}", s.cwds);
        s.add_cwd(home.join("code/p").to_str().unwrap());
        assert_eq!(s.cwds, [home.join("code/p")]);
    }

    #[test]
    fn cwd_that_contains_the_haunt_dir_is_ignored() {
        let root = tempdir("contains");
        std::fs::create_dir_all(root.join("proj/.haunt")).unwrap();
        let mut s = FsScope::new(&["${cwd}/*".into()], &[], Some(&root.join("proj/.haunt")));
        s.home = Some(PathBuf::from("/nonexistent/home"));
        s.add_cwd(root.join("proj").to_str().unwrap());
        assert!(s.cwds.is_empty(), "{:?}", s.cwds);
    }

    #[test]
    fn unknown_home_means_no_cwd_at_all() {
        let root = tempdir("nohome");
        let mut s = FsScope::new(&["${cwd}/.claude/*.json".into()], &[], None);
        s.home = None;
        s.add_cwd(root.join("proj").to_str().unwrap());
        assert!(s.cwds.is_empty());
    }

    #[test]
    fn the_haunt_dir_is_off_limits_whatever_the_grant() {
        let root = tempdir("hauntfs");
        let haunt = root.join("haunt");
        std::fs::create_dir_all(haunt.join("plugins")).unwrap();
        std::fs::write(haunt.join("plugins.lock"), "x").unwrap();
        let g = format!("{}/*", haunt.display());
        let s = FsScope::new(&[g.clone(), format!("{}/*", root.display())], std::slice::from_ref(&g), Some(&haunt));
        let lock = haunt.join("plugins.lock");
        assert!(s.read(lock.to_str().unwrap()).unwrap_err().contains("not covered"));
        assert!(s.write(lock.to_str().unwrap(), b"pwned").unwrap_err().contains("not covered"));
        assert_eq!(std::fs::read(&lock).unwrap(), b"x");
        assert!(s.list(haunt.to_str().unwrap()).is_err());
        assert_eq!(s.list(root.to_str().unwrap()).unwrap(), ["proj"], "the haunt dir is not listed either");
    }
}
