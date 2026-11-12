//! Chords as `[keys]` writes them ("cmd+shift+p"), in the app's canonical spelling: `cmd+ctrl+opt+shift+`
//! then the key's name (`Shortcut.canonical` in macos/Sources/Keys.swift).

const PUNCT: [(&str, &str); 22] = [
    (",", "comma"), (".", "period"), ("/", "slash"), (";", "semicolon"), ("'", "quote"), ("[", "bracket_left"),
    ("]", "bracket_right"), ("-", "minus"), ("=", "equal"), ("`", "backquote"), ("\\", "backslash"),
    ("comma", "comma"), ("period", "period"), ("slash", "slash"), ("semicolon", "semicolon"), ("quote", "quote"),
    ("bracket_left", "bracket_left"), ("bracket_right", "bracket_right"), ("minus", "minus"), ("equal", "equal"),
    ("backquote", "backquote"), ("backslash", "backslash"),
];

const NAMED: [&str; 14] =
    ["enter", "tab", "space", "escape", "backspace", "delete", "up", "down", "left", "right", "home", "end", "page_up", "page_down"];

fn key_name(k: &str) -> Option<String> {
    let alias = match k {
        "return" => "enter",
        "esc" => "escape",
        k => k,
    };
    let single = alias.len() == 1 && alias.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit());
    let fkey = alias.strip_prefix('f').and_then(|n| n.parse::<u8>().ok()).is_some_and(|n| (1..=12).contains(&n)) && !alias.starts_with("f0");
    if single || fkey || NAMED.contains(&alias) {
        return Some(alias.to_owned());
    }
    PUNCT.iter().find(|(p, _)| *p == alias).map(|(_, n)| (*n).to_owned())
}

/// The canonical spelling of a chord with cmd, or nil for anything else: a plugin key without cmd would
/// be terminal input.
pub fn canonical_with_cmd(text: &str) -> Option<String> {
    let lower = text.to_lowercase();
    let parts: Vec<&str> = lower.split('+').map(str::trim).collect();
    let (key, mods) = parts.split_last()?;
    if key.is_empty() || parts.len() > 5 {
        return None;
    }
    let mut on = [false; 4];
    for m in mods {
        let i = match *m {
            "cmd" | "command" | "super" => 0,
            "ctrl" | "control" => 1,
            "opt" | "option" | "alt" => 2,
            "shift" => 3,
            _ => return None,
        };
        if std::mem::replace(&mut on[i], true) {
            return None;
        }
    }
    let key = key_name(key)?;
    if !on[0] {
        return None;
    }
    let names = ["cmd+", "ctrl+", "opt+", "shift+"];
    Some(names.iter().zip(on).filter(|(_, o)| *o).map(|(n, _)| *n).collect::<String>() + &key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chords_are_spelled_one_way_and_need_cmd() {
        assert_eq!(canonical_with_cmd("Shift + CMD + P").as_deref(), Some("cmd+shift+p"));
        assert_eq!(canonical_with_cmd("alt+super+]").as_deref(), Some("cmd+opt+bracket_right"));
        assert_eq!(canonical_with_cmd("cmd+ctrl+return").as_deref(), Some("cmd+ctrl+enter"));
        assert_eq!(canonical_with_cmd("cmd+f12").as_deref(), Some("cmd+f12"));
        for bad in ["ctrl+p", "f5", "cmd+", "cmd+cmd+p", "cmd+hyper+p", "cmd+f13", "cmd+f01", "cmd+pp", "cmd+é", ""] {
            assert_eq!(canonical_with_cmd(bad), None, "{bad}");
        }
    }
}
