//! The only path from a plugin's pty request to bytes in a terminal.

use crate::model::Core;
use crate::plugins::HostRequest;

/// Bytes for `ghostty_surface_text` on `surface_id`.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PtyWrite {
    pub surface_id: String,
    pub bytes: Vec<u8>,
}

impl Core {
    /// A `PtyAnswer` becomes Allow or Deny bytes only through `answer_permission`: its key must be
    /// that surface's live request, so a plugin can't answer another surface, a stale prompt or a
    /// suspicious one. Anything else writes nothing.
    pub fn gate_plugin_request(&self, request: &HostRequest) -> Option<PtyWrite> {
        let HostRequest::PtyAnswer { plugin_id, surface, allow, request_id } = request else { return None };
        let bytes = self.answer_by(surface, *request_id, *allow, Some(plugin_id))?;
        Some(PtyWrite { surface_id: surface.clone(), bytes })
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
}
