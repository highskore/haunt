//! The only path from a plugin's pty request to bytes in a terminal.

use crate::event::is_hidden;
use crate::model::Core;
use crate::plugins::HostRequest;

/// The most a plugin may type at once.
pub const MAX_TYPED: usize = 4096;

/// Bytes for `ghostty_surface_text` on `surface_id`; with `enter`, then a Return sent as its own key,
/// outside any paste.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PtyWrite {
    pub surface_id: String,
    pub bytes: Vec<u8>,
    pub enter: bool,
}

/// Why `text` may not be typed, or None. As for the review's Send to agent: no escape (so no bracketed
/// paste end), no newline and no other control or invisible character but a tab.
pub fn untypable(text: &str) -> Option<String> {
    if text.is_empty() {
        return Some("nothing to type".into());
    }
    if text.len() > MAX_TYPED {
        return Some(format!("more than {MAX_TYPED} bytes"));
    }
    if text.contains("\u{1b}[201~") {
        return Some("it contains a bracketed paste end".into());
    }
    let bad = text.chars().find(|&c| c != '\t' && is_hidden(c))?;
    Some(format!("it contains the control or invisible character U+{:04X}", bad as u32))
}

impl Core {
    /// A `PtyAnswer` becomes Allow or Deny bytes only through `answer_permission`: its key must be
    /// that surface's live request, so a plugin can't answer another surface, a stale prompt or a
    /// suspicious one. A `PtyType` becomes its text only while that surface is still selected with no
    /// prompt up, and only if the text passes `untypable`. Anything else writes nothing.
    pub fn gate_plugin_request(&self, request: &HostRequest) -> Option<PtyWrite> {
        match request {
            HostRequest::PtyAnswer { plugin_id, surface, allow, request_id } => {
                let bytes = self.answer_by(surface, *request_id, *allow, Some(plugin_id))?;
                Some(PtyWrite { surface_id: surface.clone(), bytes, enter: false })
            }
            HostRequest::PtyType { surface, text, enter, .. } => {
                if untypable(text).is_some() || !self.may_type_into(surface) {
                    return None;
                }
                Some(PtyWrite { surface_id: surface.clone(), bytes: text.as_bytes().to_vec(), enter: *enter })
            }
            HostRequest::Notify { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn answer(surface: &str, request_id: u64) -> HostRequest {
        HostRequest::PtyAnswer { plugin_id: "p".into(), surface: surface.into(), allow: true, request_id }
    }

    #[test]
    fn only_the_live_key_on_its_own_surface_writes() {
        let c = Core::new(format!("/tmp/haunt-gate-{}", std::process::id()));
        let a = c.register_surface("/a").unwrap();
        let b = c.register_surface("/b").unwrap();
        let perm = |env: &crate::SurfaceEnv| {
            let line = format!(
                r#"{{"v":1,"surface_id":"{}","nonce":"{}","event":"permission_seen","tool_name":"Bash","tool_input":{{"command":"git push"}}}}"#,
                env.surface_id, env.nonce
            );
            c.with_state(|st| st.handle_line(&line, std::time::Instant::now()));
            c.snapshot().groups[0].rows.iter().find(|r| r.surface_id == env.surface_id).unwrap().pending.clone().unwrap().key
        };
        let key = perm(&a);
        let notify = HostRequest::Notify { plugin_id: "p".into(), title: "t".into(), body: "b".into(), actions: vec![], binding: None };
        assert_eq!(c.gate_plugin_request(&notify), None);
        assert_eq!(c.gate_plugin_request(&answer(&b.surface_id, key)), None, "another surface");
        assert_eq!(c.gate_plugin_request(&answer(&a.surface_id, key + 1)), None, "wrong key");
        let w = c.gate_plugin_request(&answer(&a.surface_id, key)).unwrap();
        assert_eq!((w.surface_id.as_str(), w.bytes.as_slice()), (a.surface_id.as_str(), b"1".as_slice()));
        assert_eq!(c.gate_plugin_request(&answer(&a.surface_id, key)), None, "consumed");
        assert_eq!(c.decisions("", 1)[0].outcome, crate::Outcome::AllowedByPlugin { plugin_id: "p".into() });
    }

    fn typed(surface: &str, text: &str, enter: bool) -> HostRequest {
        HostRequest::PtyType { plugin_id: "p".into(), surface: surface.into(), text: text.into(), enter }
    }

    #[test]
    fn typing_needs_the_selected_tab_with_no_prompt_and_clean_text() {
        let c = Core::new(format!("/tmp/haunt-gate-type-{}", std::process::id()));
        let a = c.register_surface("/a").unwrap();
        let b = c.register_surface("/b").unwrap();
        c.select_surface(&a.surface_id);
        let w = c.gate_plugin_request(&typed(&a.surface_id, "make deploy\tENV=staging", true)).unwrap();
        assert_eq!((w.bytes.as_slice(), w.enter), (b"make deploy\tENV=staging".as_slice(), true));
        assert_eq!(c.gate_plugin_request(&typed(&b.surface_id, "ls", false)), None, "not the selected tab");
        for bad in ["", "ls\n", "ls\r", "a\u{1b}[201~rm -rf ~", "\u{1b}[A", "l\u{200b}s", "\u{202e}sl", &"x".repeat(MAX_TYPED + 1)] {
            assert!(untypable(bad).is_some(), "{bad:?}");
            assert_eq!(c.gate_plugin_request(&typed(&a.surface_id, bad, false)), None, "{bad:?}");
        }
        let line = format!(
            r#"{{"v":1,"surface_id":"{}","nonce":"{}","event":"permission_seen","tool_name":"Bash","tool_input":{{"command":"git push"}}}}"#,
            a.surface_id, a.nonce
        );
        c.with_state(|st| st.handle_line(&line, std::time::Instant::now()));
        assert_eq!(c.gate_plugin_request(&typed(&a.surface_id, "ls", false)), None, "a prompt is up");
        let key = c.snapshot().groups[0].rows.iter().find(|r| r.surface_id == a.surface_id).unwrap().pending.clone().unwrap().key;
        assert!(c.gate_plugin_request(&answer(&a.surface_id, key)).is_some());
        assert!(c.has_unresolved(&a.surface_id));
        assert_eq!(c.gate_plugin_request(&typed(&a.surface_id, "ls", false)), None, "the answered prompt may still be on screen");
    }
}
