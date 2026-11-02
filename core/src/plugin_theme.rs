//! The colour tokens plugins read through the `theme` import.

use std::sync::{Arc, OnceLock};

const MAX_TOKENS: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ThemeToken {
    /// Dotted and lowercase, like "color.hairline".
    pub name: String,
    /// "#rrggbb" or "#rrggbbaa".
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Theme {
    pub name: String,
    pub tokens: Vec<ThemeToken>,
}

impl Theme {
    /// Drops tokens with a bad name or value, so a plugin only ever sees the documented shapes.
    pub fn new(name: &str, tokens: Vec<ThemeToken>) -> Result<Self, String> {
        if !valid_name(name) {
            return Err(format!("bad theme name {name:?}"));
        }
        if tokens.len() > MAX_TOKENS {
            return Err(format!("more than {MAX_TOKENS} tokens"));
        }
        let tokens = tokens.into_iter().filter(|t| valid_name(&t.name) && valid_value(&t.value)).collect();
        Ok(Self { name: name.to_owned(), tokens })
    }

    /// Black and white: the colour tokens in `design/tokens.json`, which the app's `Tok` is generated from.
    pub fn default_shared() -> Arc<Theme> {
        static DEFAULT: OnceLock<Arc<Theme>> = OnceLock::new();
        DEFAULT
            .get_or_init(|| {
                let json: serde_json::Value = serde_json::from_str(include_str!("../../design/tokens.json")).expect("tokens.json parses");
                let tokens = json["tokens"]
                    .as_object()
                    .into_iter()
                    .flatten()
                    .filter(|(k, _)| k.starts_with("color."))
                    .filter_map(|(k, v)| Some(ThemeToken { name: k.clone(), value: v["value"].as_str()?.to_owned() }))
                    .collect();
                Arc::new(Theme::new("default", tokens).expect("the default theme is valid"))
            })
            .clone()
    }
}

fn valid_name(s: &str) -> bool {
    (1..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-')
}

fn valid_value(s: &str) -> bool {
    matches!(s.len(), 7 | 9) && s.starts_with('#') && s[1..].bytes().all(|b| b.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_is_the_design_tokens_colours() {
        let t = Theme::default_shared();
        assert_eq!(t.name, "default");
        assert!(t.tokens.len() > 50, "{}", t.tokens.len());
        assert!(t.tokens.iter().all(|t| t.name.starts_with("color.")));
        assert!(t.tokens.iter().any(|t| t.name == "color.hairline"));
    }

    #[test]
    fn bad_tokens_are_dropped_and_bad_names_refused() {
        let tok = |n: &str, v: &str| ThemeToken { name: n.into(), value: v.into() };
        let t = Theme::new("glass", vec![tok("color.a", "#0b0b0b"), tok("color.b", "#0b0b0b80"), tok("Color.C", "#000000"), tok("color.d", "red"), tok("color.e", "#12345")]).unwrap();
        assert_eq!(t.tokens.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["color.a", "color.b"]);
        assert!(Theme::new("Glass!", Vec::new()).is_err());
        assert!(Theme::new("x", vec![tok("color.a", "#000000"); MAX_TOKENS + 1]).is_err());
    }
}
