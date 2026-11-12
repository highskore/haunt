//! Data-only plugins: a manifest with no `entry`, carrying one theme (`[contributes.theme]`) and its fonts.
//! They run no code; the store copies and pins their files and the app reads them from the plugin folder.

use std::fs;
use std::path::{Component, Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::plugin_manifest::{Capabilities, Manifest, ManifestError};

pub const THEME_CAP: u64 = 256 << 10;
pub const FONT_CAP: u64 = 8 << 20;
pub const PACK_CAP: u64 = 24 << 20;
const FONT_EXTS: &[&str] = &["ttf", "otf", "ttc"];

/// `[contributes.theme]`.
#[derive(Debug, Clone, PartialEq)]
pub struct ThemePack {
    /// What `theme = "<id>"` names.
    pub id: String,
    pub file: String,
    pub fonts: Vec<String>,
    pub licenses: Vec<String>,
}

/// An installed theme, with absolute paths inside its plugin's folder.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ThemeContribution {
    pub plugin_id: String,
    pub id: String,
    pub file: String,
    pub fonts: Vec<String>,
    /// Installed from the signed app: only then may its fonts draw the terminal.
    pub bundled: bool,
}

fn err<T>(m: String) -> Result<T, ManifestError> {
    Err(ManifestError(m))
}

fn plain(path: &str) -> bool {
    !path.is_empty() && Path::new(path).components().all(|c| matches!(c, Component::Normal(_)))
}

fn strings(t: &toml::Table, key: &str) -> Result<Vec<String>, ManifestError> {
    match t.get(key) {
        None => Ok(Vec::new()),
        Some(toml::Value::Array(a)) => a
            .iter()
            .map(|v| v.as_str().map(str::to_owned).ok_or_else(|| ManifestError(format!("[contributes.theme] {key} must be a list of paths"))))
            .collect(),
        Some(_) => err(format!("[contributes.theme] {key} must be a list of paths")),
    }
}

/// The theme a manifest contributes, checked; None when it has no `[contributes.theme]`.
pub fn theme_pack(m: &Manifest) -> Result<Option<ThemePack>, ManifestError> {
    let Some(v) = m.contributes.get("theme") else { return Ok(None) };
    let Some(t) = v.as_table() else { return err("[contributes.theme] must be a table".into()) };
    if let Some(k) = t.keys().find(|k| !["id", "file", "fonts", "licenses"].contains(&k.as_str())) {
        return err(format!("unknown key {k:?} in [contributes.theme]"));
    }
    let id = t.get("id").and_then(|v| v.as_str()).unwrap_or_default().to_owned();
    if id.is_empty() || id == "bw" || !id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-') {
        return err(format!("[contributes.theme] id {id:?} must be lowercase letters, digits and '-', and not \"bw\""));
    }
    let file = t.get("file").and_then(|v| v.as_str()).unwrap_or_default().to_owned();
    let (fonts, licenses) = (strings(t, "fonts")?, strings(t, "licenses")?);
    for p in std::iter::once(&file).chain(&fonts).chain(&licenses) {
        if !plain(p) {
            return err(format!("[contributes.theme] path {p:?} must be relative and inside the plugin folder"));
        }
    }
    if !file.ends_with(".toml") {
        return err("[contributes.theme] file must be a .toml".into());
    }
    if let Some(f) = fonts.iter().find(|f| !FONT_EXTS.iter().any(|e| f.to_ascii_lowercase().ends_with(&format!(".{e}")))) {
        return err(format!("[contributes.theme] font {f:?} must be .ttf, .otf or .ttc"));
    }
    if !fonts.is_empty() && licenses.is_empty() {
        return err("[contributes.theme] fonts need their licence files in licenses".into());
    }
    Ok(Some(ThemePack { id, file, fonts, licenses }))
}

/// A manifest without `entry` must be a theme and nothing else.
pub fn validate_data_only(m: &Manifest) -> Result<(), ManifestError> {
    let theme_only = Capabilities { theme: true, ..Default::default() };
    match (&m.plugin.entry, m.capabilities.theme) {
        (None, _) if m.capabilities != theme_only => err("a plugin without entry carries data only: its only capability must be theme".into()),
        (None, _) if theme_pack(m)?.is_none() => err("a plugin without entry must contribute a theme in [contributes.theme]".into()),
        (Some(_), true) => err("capability theme is for data-only plugins in this version: leave out entry".into()),
        _ => Ok(()),
    }
}

/// Every file the pack declares, read from `dir` within the caps: (relative path, bytes), sorted.
/// A file that is a symlink, or sits in a folder that leads out of `dir`, is refused.
pub fn read_files(dir: &Path, pack: &ThemePack) -> Result<Vec<(String, Vec<u8>)>, String> {
    let root = dir.canonicalize().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    let mut total = 0;
    let caps = std::iter::once((&pack.file, THEME_CAP)).chain(pack.fonts.iter().map(|f| (f, FONT_CAP))).chain(pack.licenses.iter().map(|l| (l, THEME_CAP)));
    for (rel, cap) in caps {
        let path = root.join(rel);
        let parent = path.parent().and_then(|p| p.canonicalize().ok());
        if !parent.is_some_and(|p| p.starts_with(&root)) {
            return Err(format!("{rel} is not inside the plugin folder"));
        }
        let bytes = read_capped(&path, rel, cap)?;
        total += bytes.len() as u64;
        if total > PACK_CAP {
            return Err(format!("the theme's files are larger than {PACK_CAP} bytes together"));
        }
        out.push((rel.clone(), bytes));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out.dedup_by(|a, b| a.0 == b.0);
    Ok(out)
}

/// `path`'s bytes, opened without following a symlink and checked on the open handle, so a swap between
/// the check and the read can't slip in another file or a larger one.
fn read_capped(path: &Path, rel: &str, cap: u64) -> Result<Vec<u8>, String> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|e| if e.raw_os_error() == Some(libc::ELOOP) { format!("{rel} is not a regular file") } else { format!("{rel}: {e}") })?;
    if !file.metadata().map_err(|e| format!("{rel}: {e}"))?.is_file() {
        return Err(format!("{rel} is not a regular file"));
    }
    let mut bytes = Vec::new();
    file.take(cap + 1).read_to_end(&mut bytes).map_err(|e| format!("{rel}: {e}"))?;
    if bytes.len() as u64 > cap {
        return Err(format!("{rel} is larger than {cap} bytes"));
    }
    Ok(bytes)
}

/// One digest over every file's name and contents, for the lockfile.
pub fn files_digest(files: &[(String, Vec<u8>)]) -> String {
    let mut h = Sha256::new();
    for (name, bytes) in files {
        h.update(name.as_bytes());
        h.update([0]);
        h.update(Sha256::digest(bytes));
    }
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// The installed theme's paths, each checked to resolve inside `dir` (no symlink out of the folder).
pub fn contribution(plugin_id: &str, dir: &Path, pack: &ThemePack, bundled: bool) -> Result<ThemeContribution, String> {
    let root = dir.canonicalize().map_err(|e| e.to_string())?;
    let inside = |rel: &str| -> Result<String, String> {
        let p: PathBuf = root.join(rel).canonicalize().map_err(|e| format!("{rel}: {e}"))?;
        if !p.starts_with(&root) {
            return Err(format!("{rel} resolves outside the plugin folder"));
        }
        Ok(p.to_string_lossy().into_owned())
    };
    Ok(ThemeContribution {
        plugin_id: plugin_id.to_owned(),
        id: pack.id.clone(),
        file: inside(&pack.file)?,
        fonts: pack.fonts.iter().map(|f| inside(f)).collect::<Result<_, _>>()?,
        bundled,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugin_manifest::MANIFEST;
    use crate::plugin_store::{Installed, Preview, Store, StoreError};
    use crate::plugins::PluginHost;
    use crate::testdir::TempDir;

    const THEME: &str = "[plugin]\nid = \"dev.haunt.theme-glass\"\nname = \"Glass\"\nversion = \"0.1.0\"\napi = \"0.4\"\n\
        [capabilities]\ntheme = true\n[contributes.theme]\nid = \"glass\"\nfile = \"theme.toml\"\nfonts = [\"fonts/A.ttf\"]\nlicenses = [\"OFL.txt\"]\n";

    fn pack(dir: &Path, manifest: &str) -> PathBuf {
        let s = dir.join("src");
        fs::create_dir_all(s.join("fonts")).unwrap();
        fs::write(s.join(MANIFEST), manifest).unwrap();
        fs::write(s.join("theme.toml"), "name = \"Glass\"\n[color]\nwindow.bg = \"#102030\"\n").unwrap();
        fs::write(s.join("fonts/A.ttf"), "font").unwrap();
        fs::write(s.join("OFL.txt"), "licence").unwrap();
        s
    }

    fn manifest(contributes: &str, caps: &str, entry: &str) -> Result<Manifest, ManifestError> {
        Manifest::parse(&format!(
            "[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"0.1.0\"\napi = \"0.4\"\n{entry}\n[capabilities]\n{caps}\n[contributes.theme]\n{contributes}\n"
        ))
    }

    #[test]
    fn a_theme_pack_names_plain_paths_inside_the_folder() {
        let ok = "id = \"glass\"\nfile = \"theme.toml\"\nfonts = [\"f/A.otf\"]\nlicenses = [\"OFL.txt\"]";
        assert!(manifest(ok, "theme = true", "").is_ok());
        for (bad, why) in [
            ("id = \"bw\"\nfile = \"t.toml\"", "and not"),
            ("id = \"Glass\"\nfile = \"t.toml\"", "lowercase"),
            ("file = \"t.toml\"", "lowercase"),
            ("id = \"g\"\nfile = \"../t.toml\"", "inside the plugin folder"),
            ("id = \"g\"\nfile = \"/etc/t.toml\"", "inside the plugin folder"),
            ("id = \"g\"\nfile = \"t.json\"", "must be a .toml"),
            ("id = \"g\"\nfile = \"t.toml\"\nfonts = [\"a.woff\"]\nlicenses = [\"L\"]", ".ttf, .otf or .ttc"),
            ("id = \"g\"\nfile = \"t.toml\"\nfonts = [\"a.ttf\"]", "licence files"),
            ("id = \"g\"\nfile = \"t.toml\"\nscript = \"x\"", "unknown key"),
        ] {
            let e = manifest(bad, "theme = true", "").unwrap_err().0;
            assert!(e.contains(why), "{bad}: {e}");
        }
    }

    #[test]
    fn a_data_only_plugin_has_the_theme_capability_and_nothing_else() {
        let t = "id = \"g\"\nfile = \"t.toml\"";
        assert!(manifest(t, "theme = true\nnotifications = true", "").unwrap_err().0.contains("only capability must be theme"));
        assert!(manifest(t, "", "").unwrap_err().0.contains("only capability must be theme"));
        assert!(manifest(t, "theme = true", "entry = \"p.wasm\"").unwrap_err().0.contains("leave out entry"));
        let none = Manifest::parse("[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"0.1.0\"\napi = \"0.4\"\n[capabilities]\ntheme = true\n");
        assert!(none.unwrap_err().0.contains("must contribute a theme"));
    }

    #[test]
    fn installing_copies_and_pins_the_files_and_runs_nothing() {
        let dir = TempDir::created("pack-install");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let src = pack(&dir, THEME);
        assert!(matches!(store.install(&src, &host, &mut |_| false), Err(StoreError::Declined)));
        let mut prompt = None;
        assert_eq!(store.install(&src, &host, &mut |p| { prompt = Some(p.clone()); true }).unwrap(), Installed::New);
        let prompt = prompt.unwrap();
        assert_eq!(prompt.lines, vec![("adds a theme: colours, fonts and window effects. Its fonts can change how text, including the terminal, is drawn. Runs no code".to_owned(), false)]);
        assert!(prompt.always.is_empty(), "a data-only plugin gets none of the code plugin lines");

        let listed = store.list().unwrap();
        assert_eq!((listed.len(), listed[0].problem.as_deref()), (1, None));
        assert!(listed[0].entry.sha256_wasm.is_empty() && listed[0].entry.sha256_files.len() == 64);
        let set = store.load_all(&host, None).unwrap();
        assert!(set.errors().is_empty(), "{:?}", set.errors());
        let installed = store.plugins_dir().join("dev.haunt.theme-glass").canonicalize().unwrap();
        let t = &set.themes()[0];
        assert_eq!((t.plugin_id.as_str(), t.id.as_str()), ("dev.haunt.theme-glass", "glass"));
        assert_eq!(t.file, installed.join("theme.toml").to_string_lossy());
        assert_eq!(t.fonts, vec![installed.join("fonts/A.ttf").to_string_lossy().into_owned()]);
        assert!(!t.bundled, "a theme installed from a folder is not the app's");
        assert!(installed.join("OFL.txt").is_file());

        // Same files, same grants: no prompt.
        store.install(&src, &host, &mut |_| panic!("an unchanged theme must not prompt")).unwrap();
    }

    /// A bundle folder like bundle-plugins.sh writes: `<bundle>/<id>/` with the manifest and the theme's files.
    fn bundled(dir: &Path) -> PathBuf {
        let b = dir.join("bundle/dev.haunt.theme-glass");
        fs::create_dir_all(dir.join("bundle")).unwrap();
        fs::rename(pack(dir, THEME), &b).unwrap();
        b
    }

    #[test]
    fn a_bundled_theme_installs_pinned_as_bundled_and_updates_at_launch() {
        let dir = TempDir::created("pack-bundled");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let b = bundled(&dir);
        let wrong = dir.join("bundle/dev.haunt.other");
        fs::create_dir_all(&wrong).unwrap();
        fs::copy(b.join(MANIFEST), wrong.join(MANIFEST)).unwrap();
        let e = store.install_bundled_plugin(&wrong, &host, &mut |_| true).unwrap_err().to_string();
        assert!(e.contains("its manifest is for dev.haunt.theme-glass"), "{e}");
        fs::remove_dir_all(&wrong).unwrap();

        assert_eq!(store.install_bundled_plugin(&b, &host, &mut |_| true).unwrap(), Installed::New);
        let entry = &store.list().unwrap()[0].entry;
        assert_eq!((entry.source.as_str(), entry.sha256_wasm.as_str()), ("bundled", ""));
        let t = store.load_all(&host, None).unwrap().themes()[0].clone();
        assert!(t.id == "glass" && t.bundled);

        // A new app's copy replaces the installed files without a prompt; the theme keeps loading.
        fs::write(b.join("theme.toml"), "name = \"Glass\"\n[color]\nwindow.bg = \"#405060\"\n").unwrap();
        assert!(store.install_bundled(&dir.join("bundle"), &host).unwrap().is_empty());
        let installed = store.plugins_dir().join("dev.haunt.theme-glass/theme.toml");
        assert!(fs::read_to_string(&installed).unwrap().contains("#405060"));
        let set = store.load_all(&host, None).unwrap();
        assert!(set.errors().is_empty() && set.themes().len() == 1, "{:?}", set.errors());

        // Removed, it stays removed at launch, and comes back only when asked for.
        store.remove("dev.haunt.theme-glass").unwrap();
        assert!(store.install_bundled(&dir.join("bundle"), &host).unwrap().is_empty());
        assert!(store.list().unwrap().is_empty());
        store.install_bundled_plugin(&b, &host, &mut |_| true).unwrap();
        assert_eq!(store.list().unwrap().len(), 1);
    }

    #[test]
    fn a_bundled_theme_preview_writes_nothing() {
        let dir = TempDir::created("pack-bundled-dry");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let b = bundled(&dir);
        let lock = dir.join("home/plugins.lock");
        let installed = store.plugins_dir().join("dev.haunt.theme-glass");

        let (what, prompt) = store.preview_bundled_plugin(&b, &host).unwrap();
        assert_eq!(what, Preview::Install(Installed::New));
        assert_eq!(prompt.lines.len(), 1);
        assert!(!installed.exists() && !lock.exists());

        store.install_bundled_plugin(&b, &host, &mut |_| true).unwrap();
        let (pinned, theme) = (fs::read(&lock).unwrap(), fs::read(installed.join("theme.toml")).unwrap());
        assert_eq!(store.preview_bundled_plugin(&b, &host).unwrap().0, Preview::Unchanged);
        fs::write(b.join("theme.toml"), "name = \"Glass\"\n").unwrap();
        assert_eq!(store.preview_bundled_plugin(&b, &host).unwrap().0, Preview::Install(Installed::Updated { prompted: false }));
        assert_eq!((fs::read(&lock).unwrap(), fs::read(installed.join("theme.toml")).unwrap()), (pinned, theme));
    }

    #[test]
    fn a_tampered_bundled_theme_is_repaired_by_installing_it_again() {
        let dir = TempDir::created("pack-repair");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let b = bundled(&dir);
        store.install_bundled_plugin(&b, &host, &mut |_| true).unwrap();
        let theme = store.plugins_dir().join("dev.haunt.theme-glass/theme.toml");
        let good = fs::read(&theme).unwrap();
        fs::write(&theme, "name = \"Tampered\"\n").unwrap();

        let (what, prompt) = store.preview_bundled_plugin(&b, &host).unwrap();
        assert_eq!(what, Preview::Install(Installed::Updated { prompted: false }));
        assert!(prompt.changed_on_disk);
        store.install_bundled_plugin(&b, &host, &mut |_| true).unwrap();
        assert_eq!(fs::read(&theme).unwrap(), good);
        assert_eq!(store.preview_bundled_plugin(&b, &host).unwrap().0, Preview::Unchanged);
    }

    #[test]
    fn an_update_that_adds_fonts_asks_again() {
        let dir = TempDir::created("pack-fonts-grow");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let src = pack(&dir, THEME);
        store.install(&src, &host, &mut |_| true).unwrap();
        fs::write(src.join("fonts/B.ttf"), "font").unwrap();
        fs::write(src.join(MANIFEST), THEME.replace("[\"fonts/A.ttf\"]", "[\"fonts/A.ttf\", \"fonts/B.ttf\"]")).unwrap();
        let mut lines = Vec::new();
        let e = store.install(&src, &host, &mut |p| { lines = p.lines.clone(); false }).unwrap_err();
        assert!(matches!(e, StoreError::Declined));
        assert!(lines.len() == 1 && lines[0].0.starts_with("adds or changes 1 font file(s)"), "{lines:?}");

        // A font swapped for another under the same name asks again too.
        store.install(&src, &host, &mut |_| true).unwrap();
        fs::write(src.join("fonts/A.ttf"), "a different font").unwrap();
        let e = store.install(&src, &host, &mut |p| { lines = p.lines.clone(); false }).unwrap_err();
        assert!(matches!(e, StoreError::Declined));
        assert!(lines.len() == 1 && lines[0].0.starts_with("adds or changes 1 font file(s)"), "{lines:?}");

        // A launch update of a bundled theme that adds a font goes on disk unpinned.
        let dir = TempDir::created("pack-fonts-grow-bundled");
        let store = Store::open(&dir.join("home")).unwrap();
        let b = bundled(&dir);
        store.install_bundled_plugin(&b, &host, &mut |_| true).unwrap();
        fs::write(b.join("fonts/B.ttf"), "font").unwrap();
        fs::write(b.join(MANIFEST), THEME.replace("[\"fonts/A.ttf\"]", "[\"fonts/A.ttf\", \"fonts/B.ttf\"]")).unwrap();
        store.install_bundled(&dir.join("bundle"), &host).unwrap();
        let set = store.load_all(&host, None).unwrap();
        assert!(set.themes().is_empty() && set.errors()[0].contains("does not match the lockfile"), "{:?}", set.errors());
    }

    #[test]
    fn tampered_theme_files_fail_until_approved() {
        let dir = TempDir::created("pack-tamper");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        store.install(&pack(&dir, THEME), &host, &mut |_| true).unwrap();
        let installed = store.plugins_dir().join("dev.haunt.theme-glass");
        fs::write(installed.join("fonts/A.ttf"), "other font").unwrap();
        let set = store.load_all(&host, None).unwrap();
        assert!(set.themes().is_empty());
        assert!(set.errors()[0].contains("do not match the lockfile"), "{:?}", set.errors());
        assert!(store.list().unwrap()[0].problem.is_some());

        let mut changed = false;
        store.approve("dev.haunt.theme-glass", &host, &mut |p| { changed = p.changed_on_disk; true }).unwrap();
        assert!(changed);
        assert_eq!(store.load_all(&host, None).unwrap().themes().len(), 1);
    }

    #[test]
    fn symlinks_and_oversized_files_are_refused() {
        let dir = TempDir::created("pack-links");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let outside = dir.join("outside");
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("A.ttf"), "font").unwrap();

        let src = pack(&dir, THEME);
        fs::remove_file(src.join("theme.toml")).unwrap();
        std::os::unix::fs::symlink(outside.join("A.ttf"), src.join("theme.toml")).unwrap();
        let e = store.install(&src, &host, &mut |_| true).unwrap_err().to_string();
        assert!(e.contains("not a regular file"), "{e}");

        let src = pack(&dir.join("b"), THEME);
        fs::remove_dir_all(src.join("fonts")).unwrap();
        std::os::unix::fs::symlink(&outside, src.join("fonts")).unwrap();
        let e = store.install(&src, &host, &mut |_| true).unwrap_err().to_string();
        assert!(e.contains("not inside the plugin folder"), "{e}");

        let src = pack(&dir.join("c"), THEME);
        fs::File::create(src.join("fonts/A.ttf")).unwrap().set_len(FONT_CAP + 1).unwrap();
        let e = store.install(&src, &host, &mut |_| true).unwrap_err().to_string();
        assert!(e.contains("larger than"), "{e}");
        assert!(store.list().unwrap().is_empty());
    }

    #[test]
    fn two_plugins_cannot_contribute_the_same_theme_id() {
        let dir = TempDir::created("pack-dup");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        store.install(&pack(&dir.join("a"), THEME), &host, &mut |_| true).unwrap();
        store.install(&pack(&dir.join("b"), &THEME.replace("theme-glass", "theme-glass2")), &host, &mut |_| true).unwrap();
        let set = store.load_all(&host, None).unwrap();
        assert_eq!(set.themes().len(), 1);
        assert!(set.errors()[0].contains("theme glass is already installed"), "{:?}", set.errors());
    }
}
