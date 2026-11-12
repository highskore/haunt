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

/// Folders under `$HOME` macOS guards with its own permission prompts: never a project root themselves.
const TCC_ROOTS: [&str; 7] = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents"];

/// A one-line git pointer file (`.git`, `commondir`), as git reads it: trailing `\n` and `\r` dropped and
/// nothing else. Anything git would read differently from a careful reader (another line, or leading or
/// trailing whitespace) is refused, so the path checked is the path git uses.
fn git_pointer(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok().filter(|t| t.len() < 4096)?;
    let line = text.trim_end_matches(['\n', '\r']);
    let odd = line.contains(['\n', '\r']) || line.starts_with(char::is_whitespace) || line.ends_with(char::is_whitespace);
    (!odd && !line.is_empty()).then(|| line.to_owned())
}

/// Where a `gitdir: <path>` file points, canonical; relative paths are from the file's folder.
fn git_file_target(git: &Path) -> Option<PathBuf> {
    let line = git_pointer(git)?;
    let target = line.strip_prefix("gitdir: ").filter(|t| !t.starts_with(char::is_whitespace))?;
    git.parent()?.join(target).canonicalize().ok()
}

#[derive(Debug, Default, Clone)]
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

    /// `${cwd}` expands to the project folders of tabs the plugin has seen verified agent events in, as
    /// `project_folder` resolves them. Without a known `$HOME` nothing is added.
    pub fn add_cwd(&mut self, cwd: &str) -> bool {
        let Some(c) = self.project_folder(cwd) else { return false };
        if !self.cwds.contains(&c) && self.cwds.len() < MAX_CWDS {
            self.cwds.push(c);
        }
        true
    }

    /// The git work tree `cwd` is in, canonical, if it may be a `${cwd}`. A tab's cwd comes from the shell
    /// (OSC 7), which an agent can steer, so only a repository's root counts, found by walking up from
    /// `cwd` without reaching `$HOME`; a `.git` file must point where `gitdir_allowed` says. The root must be strictly
    /// inside `$HOME`, not under a dot-folder or `~/Library`, neither inside the haunt dir nor containing
    /// it, and not itself one of the folders macOS guards (`TCC_ROOTS`), though a project inside one is
    /// fine. `exec` runs only in such a folder.
    pub fn project_folder(&self, cwd: &str) -> Option<PathBuf> {
        self.repo(cwd).map(|r| r.work_tree)
    }

    /// `project_folder` and its git dir, both from one look at `.git`: a real folder (never a link), or
    /// what a `.git` file points to.
    fn repo(&self, cwd: &str) -> Option<crate::plugin_exec::Repo> {
        let home = self.home.as_ref()?;
        let c = Path::new(cwd).canonicalize().ok()?;
        let (root, git_dir) = c.ancestors().take_while(|d| d.starts_with(home) && *d != home.as_path()).find_map(|d| {
            let git = d.join(".git");
            let git_dir = match std::fs::symlink_metadata(&git) {
                Ok(m) if m.is_dir() => git,
                Ok(m) if m.is_file() => git_file_target(&git).filter(|t| self.gitdir_allowed(t))?,
                _ => return None,
            };
            Some((d, git_dir))
        })?;
        self.may_be_root(root).then(|| crate::plugin_exec::Repo { work_tree: root.to_path_buf(), git_dir })
    }

    /// `dir` (canonical) is strictly inside `$HOME`, not under a dot-folder or `~/Library`, clear of the
    /// haunt dir both ways, and not a folder macOS guards.
    fn may_be_root(&self, dir: &Path) -> bool {
        let Some(rel) = self.home.as_ref().and_then(|h| dir.strip_prefix(h).ok()).filter(|r| !r.as_os_str().is_empty()) else { return false };
        let private = rel.components().any(|p| p.as_os_str().as_bytes().starts_with(b".")) || rel.starts_with("Library");
        let haunt = dir.starts_with(&self.haunt) || self.haunt.starts_with(dir);
        let guarded = TCC_ROOTS.iter().any(|t| rel == Path::new(t));
        !private && !haunt && !guarded
    }

    /// Where a `.git` file may point (canonical): into the `.git` folder of a work tree that may itself be
    /// a root (a worktree's or submodule's gitdir), or at a folder that may be a root. A worktree's
    /// `commondir` must pass the same test, so neither half of the repository lives somewhere private.
    fn gitdir_allowed(&self, dir: &Path) -> bool {
        let ok = |d: &Path| match d.ancestors().find(|a| a.file_name().is_some_and(|n| n == ".git")) {
            Some(dot_git) => dot_git.parent().is_some_and(|w| self.may_be_root(w)),
            None => self.may_be_root(d),
        };
        let file = dir.join("commondir");
        let common = match std::fs::symlink_metadata(&file) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(dir.to_path_buf()),
            _ => git_pointer(&file).and_then(|t| dir.join(t).canonicalize().ok()),
        };
        ok(dir) && common.is_some_and(|c| ok(&c))
    }

    /// A tab's repository: the project folder it was opened in, which the app chose (never the live cwd,
    /// which the pty can steer), and that work tree's git dir, so git needn't discover either.
    pub fn tab_repo(&self, opened_in: &str) -> Option<crate::plugin_exec::Repo> {
        self.repo(opened_in)
    }

    #[cfg(test)]
    pub(crate) fn set_home(&mut self, home: &Path) {
        self.home = Some(home.canonicalize().unwrap());
    }

    pub fn cwds(&self) -> &[PathBuf] {
        &self.cwds
    }

    /// The `${cwd}` folders every grant (`fs`, `fs-list`) reaches: each strictly inside `$HOME`, never
    /// `$HOME`, `/` or an ancestor of either, and clear of the haunt dir, however it was added.
    fn roots(&self) -> impl Iterator<Item = &Path> {
        let home = self.home.as_deref();
        self.cwds.iter().map(PathBuf::as_path).filter(move |c| {
            home.is_some_and(|h| c.starts_with(h) && !h.starts_with(c)) && !c.starts_with(&self.haunt) && !self.haunt.starts_with(c)
        })
    }

    /// The project folder `full` (canonical) is in, if no folder between them starts with a dot.
    fn root_of(&self, full: &Path) -> Option<&Path> {
        let dotted = |r: &Path| r.components().any(|p| p.as_os_str().as_bytes().starts_with(b"."));
        self.roots().find(|c| full.strip_prefix(c).is_ok_and(|r| !dotted(r)))
    }

    fn patterns(&self, globs: &[String]) -> Vec<Vec<Vec<u8>>> {
        let mut out = Vec::new();
        for g in globs {
            if let Some(rest) = g.strip_prefix(CWD) {
                out.extend(self.roots().map(|c| pattern(c, rest)));
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

/// Entries `FsScope::tree` looks at, at most, before it stops with `truncated`.
pub const TREE_SCAN: usize = 50_000;
pub const TREE_DEPTH: u8 = 5;
/// After this a walk stops with what it counted; past `TREE_GIVE_UP` a stuck one is left behind.
const TREE_TIME: std::time::Duration = std::time::Duration::from_millis(1500);
const TREE_GIVE_UP: std::time::Duration = std::time::Duration::from_secs(3);

/// A folder `FsScope::tree` counted: `path` relative to the walk's root ("" for the root itself),
/// with the regular files in it and their bytes, folders past the depth included.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Folder {
    pub path: String,
    pub files: u32,
    pub bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Tree {
    pub folders: Vec<Folder>,
    pub truncated: bool,
}

/// One entry `FsScope::entries` returns: never anything of a file but its name and size.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub size: u64,
    pub dir: bool,
}

impl FsScope {
    /// Files and folders directly in `path`, a folder inside a `${cwd}` (or the `${cwd}` itself) and
    /// not under a dot-folder; sorted by name. Dot entries, symlinks and anything but regular files and
    /// folders are left out, and a folder's size is 0. No glob is needed: the `fs_list` grant is the
    /// whole project folder, for names and sizes only.
    pub fn entries(&self, path: &str) -> Result<Vec<Entry>, String> {
        let full = canonical(path)?;
        if self.root_of(&full).is_none() {
            return Err(format!("{path}: not inside an agent's project folder"));
        }
        if full.starts_with(&self.haunt) {
            return Err(denied(path));
        }
        let dir = open_dir_nofollow(&full).map_err(|e| io_err(path, e))?;
        list(dir, path, LIST_SCAN, LIST_CAP)
    }
}

impl FsScope {
    /// The folders under `path` (scoped like `entries`) down to `depth` levels (at most 5), breadth
    /// first, each with its files and bytes; files deeper down count toward their folder at `depth`.
    /// Dot entries and symlinks are skipped, never followed. Past `TREE_SCAN` entries or 1.5 s it
    /// returns what it counted with `truncated`. The walk runs on its own thread, so a stuck
    /// filesystem costs the caller at most 3 s.
    pub fn tree(&self, path: &str, depth: u8) -> Result<Tree, String> {
        if depth > TREE_DEPTH {
            return Err(format!("depth is at most {TREE_DEPTH}"));
        }
        let full = canonical(path)?;
        if self.root_of(&full).is_none() || full.starts_with(&self.haunt) {
            return Err(format!("{path}: not inside an agent's project folder"));
        }
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("haunt-fs-tree".into())
            .spawn(move || {
                let _ = tx.send(walk(&full, depth, TREE_SCAN, std::time::Instant::now() + TREE_TIME));
            })
            .map_err(|e| e.to_string())?;
        rx.recv_timeout(TREE_GIVE_UP).map_err(|_| format!("{path}: the folder didn't answer in time"))?.map_err(|e| io_err(path, e))
    }
}

fn walk(root: &Path, depth: u8, scan: usize, deadline: std::time::Instant) -> io::Result<Tree> {
    let mut tree = Tree::default();
    let mut seen = 0usize;
    // (path relative to root, levels below root, index of the folder its files count toward)
    let mut queue = std::collections::VecDeque::from([(PathBuf::new(), 0u8, 0usize)]);
    tree.folders.push(Folder { path: String::new(), files: 0, bytes: 0 });
    while let Some((rel, level, owner)) = queue.pop_front() {
        let Ok(fd) = open_dir_nofollow(&root.join(&rel)) else { continue };
        let stop = each_entry(fd, |e| {
            seen += 1;
            if seen > scan || std::time::Instant::now() > deadline {
                tree.truncated = true;
                return false;
            }
            let Some((name, st)) = e else { return true };
            match st.st_mode & libc::S_IFMT {
                libc::S_IFREG => {
                    let f = &mut tree.folders[owner];
                    f.files = f.files.saturating_add(1);
                    f.bytes = f.bytes.saturating_add(st.st_size as u64);
                }
                libc::S_IFDIR => {
                    let child = rel.join(std::ffi::OsStr::from_bytes(name));
                    let owner = if level < depth {
                        tree.folders.push(Folder { path: child.to_string_lossy().into_owned(), files: 0, bytes: 0 });
                        tree.folders.len() - 1
                    } else {
                        owner
                    };
                    queue.push_back((child, level.saturating_add(1), owner));
                }
                _ => {}
            }
            true
        })?;
        if !stop {
            break;
        }
    }
    tree.folders.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(tree)
}

/// Calls `f(name, stat)` for each entry of the open folder `fd` but `.`, `..` and dot names, without
/// following a symlink, until `f` returns false; returns whether it went through them all.
/// Calls `f` for every entry of the folder `fd` but `.` and `..`, with its name and lstat, or `None` for
/// a dot entry or one that can't be stat'ed, so a caller's caps count those too. Whether `f` never stopped.
fn each_entry(fd: OwnedFd, mut f: impl FnMut(Option<(&[u8], &libc::stat)>) -> bool) -> io::Result<bool> {
    use std::os::fd::IntoRawFd;
    let raw = fd.into_raw_fd();
    let dir = unsafe { libc::fdopendir(raw) };
    if dir.is_null() {
        let e = io::Error::last_os_error();
        unsafe { libc::close(raw) };
        return Err(e);
    }
    let dfd = unsafe { libc::dirfd(dir) };
    let mut all = true;
    loop {
        let e = unsafe { libc::readdir(dir) };
        if e.is_null() {
            break;
        }
        let name = unsafe { std::ffi::CStr::from_ptr((*e).d_name.as_ptr()) };
        let bytes = name.to_bytes();
        if bytes == b"." || bytes == b".." {
            continue;
        }
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        let shown = !bytes.starts_with(b".") && unsafe { libc::fstatat(dfd, name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) } == 0;
        if !f(shown.then_some((bytes, &st))) {
            all = false;
            break;
        }
    }
    unsafe { libc::closedir(dir) };
    Ok(all)
}

/// The regular files and folders in `dir`, read through that fd: an error past `scan` entries (dot ones
/// included) or `cap` listed ones.
fn list(dir: OwnedFd, path: &str, scan: usize, cap: usize) -> Result<Vec<Entry>, String> {
    let (mut out, mut seen, mut over) = (Vec::new(), 0usize, None);
    each_entry(dir, |e| {
        seen += 1;
        if seen > scan {
            over = Some(format!("{path}: more than {scan} entries"));
            return false;
        }
        let Some((name, st)) = e else { return true };
        let (size, dir) = match st.st_mode & libc::S_IFMT {
            libc::S_IFREG => (st.st_size as u64, false),
            libc::S_IFDIR => (0, true),
            _ => return true,
        };
        if out.len() == cap {
            over = Some(format!("{path}: more than {cap} entries"));
            return false;
        }
        out.push(Entry { name: String::from_utf8_lossy(name).into_owned(), size, dir });
        true
    })
    .map_err(|e| io_err(path, e))?;
    if let Some(e) = over {
        return Err(e);
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
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
        std::fs::create_dir_all(d.join("proj/.git")).unwrap();
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
    fn a_tab_in_home_or_a_plain_folder_lists_nothing() {
        let root = tempdir("wide");
        std::fs::create_dir_all(root.join("code/plain")).unwrap();
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::create_dir_all(root.join("Documents/.git")).unwrap();
        let mut s = FsScope::new(&["${cwd}/*".into()], &[], None);
        s.home = Some(root.canonicalize().unwrap());
        for tab in [root.to_path_buf(), root.join("code"), root.join("code/plain"), root.join("Documents")] {
            assert!(!s.add_cwd(tab.to_str().unwrap()), "{}", tab.display());
        }
        for dir in [root.to_path_buf(), root.join("code"), root.join("Documents")] {
            assert!(s.entries(dir.to_str().unwrap()).unwrap_err().contains("not inside"), "{}", dir.display());
        }
        // Even a too-wide folder that got into the list reaches nothing, for listing or reading.
        s.cwds.push(root.canonicalize().unwrap());
        assert!(s.entries(root.to_str().unwrap()).is_err());
        std::fs::write(root.join("notes.txt"), "x").unwrap();
        assert!(s.read(root.join("notes.txt").to_str().unwrap()).is_err());
        assert!(s.entries(root.join("proj").to_str().unwrap()).is_err());
    }

    #[test]
    fn a_tree_counts_folders_skips_dots_and_never_follows_a_symlink() {
        let root = tempdir("tree");
        let s = scope(&root);
        let proj = root.join("proj");
        for d in ["src/api/deep/deeper", "docs", ".hidden", "src/.cache"] {
            std::fs::create_dir_all(proj.join(d)).unwrap();
        }
        std::fs::write(proj.join("README.md"), "12345").unwrap();
        std::fs::write(proj.join("src/api/a.rs"), "abc").unwrap();
        std::fs::write(proj.join("src/api/deep/deeper/b.rs"), "abcd").unwrap();
        std::fs::write(proj.join(".hidden/secret"), "x").unwrap();
        std::fs::write(proj.join("src/.cache/c"), "x").unwrap();
        symlink(&proj, proj.join("src/loop")).unwrap();
        symlink(root.join(".."), proj.join("docs/up")).unwrap();

        let t = s.tree(proj.to_str().unwrap(), 2).unwrap();
        let got: Vec<(&str, u32, u64)> = t.folders.iter().map(|f| (f.path.as_str(), f.files, f.bytes)).collect();
        assert_eq!(got, [("", 1, 5), ("docs", 0, 0), ("src", 0, 0), ("src/api", 2, 7)], "deeper files count toward src/api");
        assert!(!t.truncated);
        assert_eq!(s.tree(proj.to_str().unwrap(), 0).unwrap().folders, [Folder { path: String::new(), files: 3, bytes: 12 }]);
        assert!(s.tree(proj.to_str().unwrap(), TREE_DEPTH + 1).is_err());
        assert!(s.tree(root.to_str().unwrap(), 1).unwrap_err().contains("not inside"));
        assert!(s.tree(proj.join(".hidden").to_str().unwrap(), 1).is_err());
    }

    #[test]
    fn a_tree_past_its_scan_cap_is_truncated() {
        let root = tempdir("tree-cap");
        // Its own folder: the fixture's .claude and .git would count toward the cap too.
        let proj = root.join("proj/flat");
        std::fs::create_dir_all(&proj).unwrap();
        for i in 0..30 {
            std::fs::write(proj.join(format!("f{i}")), "x").unwrap();
        }
        let t = walk(&proj.canonicalize().unwrap(), 3, 10, std::time::Instant::now() + TREE_TIME).unwrap();
        assert!(t.truncated && t.folders[0].files == 10, "{t:?}");
        let t = walk(&proj.canonicalize().unwrap(), 3, 10, std::time::Instant::now()).unwrap();
        assert!(t.truncated && t.folders[0].files == 0, "past the deadline: {t:?}");
    }

    #[test]
    fn dot_entries_count_toward_the_tree_cap() {
        let root = tempdir("tree-dots");
        let proj = root.join("proj");
        for i in 0..30 {
            std::fs::write(proj.join(format!(".d{i}")), "x").unwrap();
        }
        let t = walk(&proj.canonicalize().unwrap(), 3, 10, std::time::Instant::now() + TREE_TIME).unwrap();
        assert!(t.truncated && t.folders[0].files == 0, "a folder of dotfiles can't keep the walk going: {t:?}");
        let t = walk(&proj.canonicalize().unwrap(), 3, 10, std::time::Instant::now()).unwrap();
        assert!(t.truncated, "nor run past the deadline: {t:?}");
    }

    #[test]
    fn a_listing_reads_the_folder_it_opened() {
        let root = tempdir("list-fd");
        let src = root.join("proj/src");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("a.rs"), "a").unwrap();
        let fd = open_dir_nofollow(&src.canonicalize().unwrap()).unwrap();
        std::fs::rename(&src, root.join("proj/old")).unwrap();
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("swapped.rs"), "b").unwrap();
        assert_eq!(list(fd, "src", LIST_SCAN, LIST_CAP).unwrap(), [Entry { name: "a.rs".into(), size: 1, dir: false }], "the folder swapped in after the open is not listed");

        for i in 0..5 {
            std::fs::write(src.join(format!(".h{i}")), "").unwrap();
        }
        let fd = || open_dir_nofollow(&src.canonicalize().unwrap()).unwrap();
        assert!(list(fd(), "src", 4, LIST_CAP).unwrap_err().contains("more than 4 entries"), "dot entries count toward the scan cap");
        assert!(list(fd(), "src", LIST_SCAN, 0).unwrap_err().contains("more than 0 entries"));
    }

    #[test]
    fn entries_are_names_and_sizes_inside_the_project_folder_only() {
        let root = tempdir("entries");
        let s = scope(&root);
        std::fs::create_dir_all(root.join("proj/src")).unwrap();
        std::fs::write(root.join("proj/src/main.rs"), "fn main() {}").unwrap();
        std::fs::write(root.join("proj/.env"), "KEY=1").unwrap();
        std::fs::write(root.join("outside.txt"), "x").unwrap();
        symlink(root.join("outside.txt"), root.join("proj/link.txt")).unwrap();
        symlink(root.join(".."), root.join("proj/up")).unwrap();
        let proj = root.join("proj");
        assert_eq!(s.entries(proj.to_str().unwrap()).unwrap(), [Entry { name: "src".into(), size: 0, dir: true }], "no dot entries or symlinks");
        assert_eq!(s.entries(proj.join("src").to_str().unwrap()).unwrap(), [Entry { name: "main.rs".into(), size: 12, dir: false }]);
        assert!(s.entries(proj.join(".claude").to_str().unwrap()).is_err(), "not under a dot-folder");
        assert!(s.entries(root.to_str().unwrap()).unwrap_err().contains("not inside"));
        assert!(s.entries(&format!("{}/src/..", proj.display())).is_err());
        assert!(s.entries(proj.join("up").to_str().unwrap()).is_err(), "a symlink resolves outside");
        assert!(s.entries("proj").is_err(), "absolute paths only");
        let none = FsScope::new(&[], &[], None);
        assert!(none.entries(proj.to_str().unwrap()).is_err(), "no project folder seen yet");
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
    fn cwd_is_a_git_root_inside_home_and_never_private_guarded_or_the_haunt_dir() {
        let root = tempdir("wide");
        let home = root.join("Users/me");
        let git = |d: &str| std::fs::create_dir_all(home.join(d).join(".git")).unwrap();
        let refused = [".ssh", ".config/gh", "Library/x", "Documents", "Desktop", "Downloads", "Library/Mobile Documents", ".haunt"];
        for d in refused.iter().chain(&["", "code/p", "Documents/proj"]) {
            git(d);
        }
        std::fs::create_dir_all(home.join("code/p/src/deep")).unwrap();
        std::fs::create_dir_all(home.join("code/plain")).unwrap();
        std::fs::create_dir_all(root.join("outside/.git")).unwrap();
        std::fs::create_dir_all(home.join("code/wt")).unwrap();
        std::fs::write(home.join("code/wt/.git"), format!("gitdir: {}\n", root.join("outside/.git").display())).unwrap();
        std::fs::create_dir_all(home.join("code/ok-wt")).unwrap();
        std::fs::write(home.join("code/ok-wt/.git"), "gitdir: ../p/.git\n").unwrap();
        symlink(home.join(".ssh"), home.join("code/ssh-link")).unwrap();
        let mut s = FsScope::new(&["${cwd}/*".into()], &[], Some(&home.join(".haunt")));
        s.home = Some(home.canonicalize().unwrap());
        let resolved = |s: &FsScope, d: &str| s.project_folder(home.join(d).to_str().unwrap());
        for d in refused.iter().chain(&["", "code/plain", "code/wt", "code/ssh-link", "Library"]) {
            assert_eq!(resolved(&s, d), None, "{d:?}");
        }
        assert_eq!(s.project_folder(root.join("outside").to_str().unwrap()), None);
        let canon = |d: &str| home.join(d).canonicalize().unwrap();
        assert_eq!(resolved(&s, "code/p/src/deep"), Some(canon("code/p")), "a tab deep in a repo grants its root");
        assert_eq!(resolved(&s, "Documents/proj"), Some(canon("Documents/proj")), "a project inside a guarded folder is fine");
        assert_eq!(resolved(&s, "code/ok-wt"), Some(canon("code/ok-wt")));
        assert!(!s.add_cwd(home.join(".ssh").to_str().unwrap()) && s.cwds.is_empty());
        assert!(s.add_cwd(home.join("code/p").to_str().unwrap()));
        assert_eq!(s.cwds, [canon("code/p")]);
    }

    #[test]
    fn a_git_file_points_only_into_a_repo_that_could_be_a_root() {
        let root = TempDir::created("gitdir");
        let home = root.join("home");
        let mkdir = |d: &str| std::fs::create_dir_all(home.join(d)).unwrap();
        let write = |f: &str, text: &str| std::fs::write(home.join(f), text).unwrap();
        for d in ["code/m/.git/worktrees/w", "code/m/.git/worktrees/evil", "code/super/.git/modules/sub", "code/super/sub", ".ssh/.git", "Library/x", ".haunt/r"] {
            mkdir(d);
        }
        write("code/m/.git/worktrees/w/commondir", "../..\n");
        write("code/m/.git/worktrees/evil/commondir", "../../../../../.ssh/.git\n");
        write("code/super/sub/.git", "gitdir: ../.git/modules/sub\n");
        let git_file = |name: &str, target: &str| {
            mkdir(&format!("code/{name}"));
            write(&format!("code/{name}/.git"), &format!("gitdir: {target}\n"));
        };
        git_file("w", "../m/.git/worktrees/w");
        git_file("evil-common", "../m/.git/worktrees/evil");
        git_file("to-ssh", "../../.ssh");
        git_file("to-ssh-git", "../../.ssh/.git");
        git_file("to-library", "../../Library/x");
        git_file("to-haunt", "../../.haunt/r");
        git_file("to-home", "../..");
        let mut s = FsScope::new(&[], &[], Some(&home.join(".haunt")));
        s.set_home(&home);
        let resolved = |d: &str| s.project_folder(home.join(d).to_str().unwrap());
        let canon = |d: &str| home.join(d).canonicalize().unwrap();
        assert_eq!(resolved("code/w"), Some(canon("code/w")), "a worktree of a repo under home");
        assert_eq!(resolved("code/super/sub"), Some(canon("code/super/sub")), "a submodule");
        for d in ["code/evil-common", "code/to-ssh", "code/to-ssh-git", "code/to-library", "code/to-haunt", "code/to-home"] {
            assert_eq!(resolved(d), None, "{d}");
        }

        // Read as git reads them: only trailing newlines go, so whitespace git keeps is refused, not trimmed.
        mkdir("code/m/.git/worktrees/w2");
        write("code/m/.git/worktrees/w2/commondir", "../..\r\n");
        git_file("crlf", "../m/.git/worktrees/w2\r");
        assert_eq!(resolved("code/crlf"), Some(canon("code/crlf")), "CRLF endings are fine");
        for (name, body) in [
            ("lead", "gitdir:  ../m/.git/worktrees/w"), ("trail", "gitdir: ../m/.git/worktrees/w "), ("tab", "gitdir: ../m/.git/worktrees/w\t"),
            ("nospace", "gitdir:../m/.git/worktrees/w"), ("two-lines", "gitdir: ../m/.git/worktrees/w\nx"),
        ] {
            mkdir(&format!("code/{name}"));
            write(&format!("code/{name}/.git"), &format!("{body}\n"));
            assert_eq!(resolved(&format!("code/{name}")), None, "{name}");
        }
        for (name, common) in [("c-lead", " ../.."), ("c-trail", "../.. "), ("c-lines", "../..\n../..")] {
            mkdir(&format!("code/m/.git/worktrees/{name}"));
            write(&format!("code/m/.git/worktrees/{name}/commondir"), &format!("{common}\n"));
            git_file(name, &format!("../m/.git/worktrees/{name}"));
            assert_eq!(resolved(&format!("code/{name}")), None, "{name}");
        }
    }

    #[test]
    fn a_tabs_repo_is_where_it_was_opened_with_its_git_dir() {
        let root = TempDir::created("tab-repo");
        let home = root.join("home");
        for d in ["code/p/.git", "code/p/src", "code/m/.git/worktrees/w", "code/w"] {
            std::fs::create_dir_all(home.join(d)).unwrap();
        }
        std::fs::write(home.join("code/m/.git/worktrees/w/commondir"), "../..\n").unwrap();
        std::fs::write(home.join("code/w/.git"), "gitdir: ../m/.git/worktrees/w\n").unwrap();
        let mut s = FsScope::new(&[], &[], Some(&root.join("haunt")));
        s.set_home(&home);
        let canon = |d: &str| home.join(d).canonicalize().unwrap();
        let repo = |d: &str| s.tab_repo(home.join(d).to_str().unwrap()).map(|r| (r.work_tree, r.git_dir));
        assert_eq!(repo("code/p/src"), Some((canon("code/p"), canon("code/p/.git"))));
        assert_eq!(repo("code/w"), Some((canon("code/w"), canon("code/m/.git/worktrees/w"))), "a worktree's own git dir");
        assert_eq!(repo(""), None, "opened at ~: no repo");
        std::fs::create_dir_all(home.join("code/s")).unwrap();
        std::os::unix::fs::symlink(home.join("code/p/.git"), home.join("code/s/.git")).unwrap();
        assert_eq!(repo("code/s"), None, "a .git that is a link is neither a root nor a git dir");
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
