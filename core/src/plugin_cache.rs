//! Compiled-component cache. A `.cwasm` is native code wasmtime maps without checks, so
//! nothing is loaded unless its HMAC verifies under a per-install key only we can read.

use std::fs::{self, DirBuilder, OpenOptions};
use std::hash::Hasher;
use std::io::{ErrorKind, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

use crate::ids::hex;

type HmacSha256 = Hmac<Sha256>;

const KEY_FILE: &str = "hmac.key";
const KEY_LEN: usize = 32;

#[derive(Debug, thiserror::Error)]
pub enum CacheError {
    #[error("cache dir {0} is unsafe: {1}")]
    UnsafeDir(PathBuf, &'static str),
    #[error("cache key {0} is unsafe: {1}")]
    UnsafeKey(PathBuf, &'static str),
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("random: {0}")]
    Random(String),
}

pub struct CwasmCache {
    dir: PathBuf,
    key: [u8; KEY_LEN],
}

/// Feeds `Hash` impls (wasmtime's compatibility hash) into SHA-256 so the key is stable.
struct ShaHasher(Sha256);

impl Hasher for ShaHasher {
    fn write(&mut self, bytes: &[u8]) {
        self.0.update(bytes);
    }
    fn finish(&self) -> u64 {
        unreachable!("only used through write")
    }
}

/// SHA-256 over the wasm's SHA-256 and the engine's compatibility hash, hex encoded.
pub fn cache_name(engine: &wasmtime::Engine, wasm_sha256: &[u8; 32]) -> String {
    let mut h = ShaHasher(Sha256::new());
    h.write(wasm_sha256);
    std::hash::Hash::hash(&engine.precompile_compatibility_hash(), &mut h);
    hex(&h.0.finalize())
}

impl CwasmCache {
    /// Creates `dir` with 0700 if missing, then refuses it unless we own it and nobody else can write.
    pub fn open(dir: &Path) -> Result<Self, CacheError> {
        DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        check_dir(dir)?;
        let key = load_or_create_key(&dir.join(KEY_FILE))?;
        Ok(Self { dir: dir.to_owned(), key })
    }

    /// Verified artefact bytes, or None. A bad or missing MAC deletes the entry.
    pub fn get(&self, name: &str) -> Option<Vec<u8>> {
        let (art, mac) = self.paths(name);
        let bytes = fs::read(&art).ok()?;
        let ok = fs::read(&mac).is_ok_and(|tag| {
            let mut m = self.mac();
            m.update(&bytes);
            m.verify_slice(&tag).is_ok()
        });
        if ok {
            Some(bytes)
        } else {
            let _ = fs::remove_file(&art);
            let _ = fs::remove_file(&mac);
            None
        }
    }

    pub fn put(&self, name: &str, bytes: &[u8]) -> Result<(), CacheError> {
        let (art, mac) = self.paths(name);
        let mut m = self.mac();
        m.update(bytes);
        write_atomic(&art, bytes)?;
        write_atomic(&mac, &m.finalize().into_bytes())?;
        Ok(())
    }

    fn paths(&self, name: &str) -> (PathBuf, PathBuf) {
        (self.dir.join(format!("{name}.cwasm")), self.dir.join(format!("{name}.cwasm.mac")))
    }

    fn mac(&self) -> HmacSha256 {
        HmacSha256::new_from_slice(&self.key).expect("hmac accepts any key length")
    }
}

pub(crate) fn check_dir(dir: &Path) -> Result<(), CacheError> {
    let unsafe_dir = |why| CacheError::UnsafeDir(dir.to_owned(), why);
    let meta = fs::symlink_metadata(dir)?;
    if !meta.is_dir() {
        return Err(unsafe_dir("not a directory"));
    }
    if meta.uid() != unsafe { libc::getuid() } {
        return Err(unsafe_dir("not owned by the current user"));
    }
    if meta.mode() & 0o022 != 0 {
        return Err(unsafe_dir("group or world writable"));
    }
    Ok(())
}

fn load_or_create_key(path: &Path) -> Result<[u8; KEY_LEN], CacheError> {
    let mut key = [0u8; KEY_LEN];
    getrandom::fill(&mut key).map_err(|e| CacheError::Random(e.to_string()))?;
    match OpenOptions::new().write(true).create_new(true).mode(0o600).custom_flags(libc::O_NOFOLLOW).open(path) {
        Ok(mut f) => {
            f.write_all(&key)?;
            f.sync_all()?;
            return Ok(key);
        }
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    let unsafe_key = |why| CacheError::UnsafeKey(path.to_owned(), why);
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_file() {
        return Err(unsafe_key("not a regular file"));
    }
    if meta.uid() != unsafe { libc::getuid() } {
        return Err(unsafe_key("not owned by the current user"));
    }
    if meta.mode() & 0o077 != 0 {
        return Err(unsafe_key("readable or writable by others"));
    }
    let bytes = fs::read(path)?;
    bytes.try_into().map_err(|_| unsafe_key("wrong length"))
}

/// Temp file created O_EXCL with 0600 in the same dir, then renamed over the target.
pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), CacheError> {
    let mut nonce = [0u8; 8];
    getrandom::fill(&mut nonce).map_err(|e| CacheError::Random(e.to_string()))?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("entry");
    let tmp = path.with_file_name(format!(".{name}.{}.tmp", hex(&nonce)));
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)?;
    let res = f.write_all(bytes).and_then(|_| f.sync_all()).and_then(|_| fs::rename(&tmp, path));
    if res.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    Ok(res?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn tempdir(tag: &str) -> PathBuf {
        let mut n = [0u8; 8];
        getrandom::fill(&mut n).unwrap();
        std::env::temp_dir().join(format!("haunt-cache-{tag}-{}", hex(&n)))
    }

    #[test]
    fn round_trips_and_creates_private_files() {
        let dir = tempdir("rt");
        let c = CwasmCache::open(&dir).unwrap();
        c.put("a", b"native code").unwrap();
        assert_eq!(c.get("a").as_deref(), Some(&b"native code"[..]));
        assert_eq!(fs::metadata(&dir).unwrap().mode() & 0o777, 0o700);
        for f in ["a.cwasm", "a.cwasm.mac", KEY_FILE] {
            assert_eq!(fs::metadata(dir.join(f)).unwrap().mode() & 0o777, 0o600, "{f}");
        }
        // A second open reuses the key, so old entries still verify.
        assert!(CwasmCache::open(&dir).unwrap().get("a").is_some());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn tampered_entry_is_rejected_and_deleted() {
        let dir = tempdir("tamper");
        let c = CwasmCache::open(&dir).unwrap();
        c.put("a", b"native code").unwrap();
        fs::write(dir.join("a.cwasm"), b"evil code!!").unwrap();
        assert!(c.get("a").is_none());
        assert!(!dir.join("a.cwasm").exists() && !dir.join("a.cwasm.mac").exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn entry_without_mac_is_rejected() {
        let dir = tempdir("nomac");
        let c = CwasmCache::open(&dir).unwrap();
        fs::write(dir.join("a.cwasm"), b"planted").unwrap();
        assert!(c.get("a").is_none());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn world_writable_dir_is_refused() {
        let dir = tempdir("ww");
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(matches!(CwasmCache::open(&dir), Err(CacheError::UnsafeDir(_, "group or world writable"))));
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o720)).unwrap();
        assert!(matches!(CwasmCache::open(&dir), Err(CacheError::UnsafeDir(..))));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn readable_key_is_refused() {
        let dir = tempdir("key");
        CwasmCache::open(&dir).unwrap();
        fs::set_permissions(dir.join(KEY_FILE), fs::Permissions::from_mode(0o644)).unwrap();
        assert!(matches!(CwasmCache::open(&dir), Err(CacheError::UnsafeKey(..))));
        fs::remove_dir_all(dir).unwrap();
    }
}
