//! One event line, parsed once and borrowed where JSON escapes allow. Lenient the way the spec
//! asks: a field of the wrong type counts as absent, unknown fields are skipped, and a repeated
//! key keeps its last value.

use std::borrow::Cow;
use std::fmt;

use serde::Deserializer;
use serde::de::{self, IgnoredAny, MapAccess, SeqAccess, Visitor};

/// A field as sent: absent, a string, or another JSON type.
#[derive(Debug, Default, PartialEq)]
pub(crate) enum Str<'a> {
    #[default]
    Absent,
    Text(Cow<'a, str>),
    Other,
}

impl<'a> Str<'a> {
    pub(crate) fn text(&self) -> Option<&str> {
        match self {
            Self::Text(s) => Some(s),
            _ => None,
        }
    }
}

/// A JSON number or bool when it is one, kept as serde_json's `as_u64` / `as_i64` / `as_bool` would.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub(crate) enum Scalar {
    #[default]
    None,
    U64(u64),
    I64(i64),
    Bool(bool),
}

impl Scalar {
    pub(crate) fn as_u64(self) -> Option<u64> {
        match self {
            Self::U64(n) => Some(n),
            _ => None,
        }
    }

    pub(crate) fn as_i64(self) -> Option<i64> {
        match self {
            Self::U64(n) => i64::try_from(n).ok(),
            Self::I64(n) => Some(n),
            _ => None,
        }
    }

    pub(crate) fn as_bool(self) -> Option<bool> {
        match self {
            Self::Bool(b) => Some(b),
            _ => None,
        }
    }
}

#[derive(Debug, Default)]
pub(crate) struct ToolInput<'a> {
    pub command: Str<'a>,
    pub url: Str<'a>,
    pub file_path: Str<'a>,
}

#[derive(Debug, Default)]
pub(crate) struct Wire<'a> {
    pub v: Scalar,
    pub agent: Str<'a>,
    pub event: Str<'a>,
    pub surface_id: Str<'a>,
    pub nonce: Str<'a>,
    pub session_id: Str<'a>,
    pub cwd: Str<'a>,
    pub agent_id: Str<'a>,
    pub agent_type: Str<'a>,
    pub truncated: Scalar,
    pub tool_name: Str<'a>,
    pub tool_use_id: Str<'a>,
    pub tool_input: ToolInput<'a>,
    pub plugin_version: Str<'a>,
    pub query: Str<'a>,
    pub task_id: Str<'a>,
    pub task_subject: Str<'a>,
    pub task_status: Str<'a>,
    pub description: Str<'a>,
    pub tool_count: Scalar,
    pub duration_ms: Scalar,
    pub todos_done: Scalar,
    pub notification_type: Str<'a>,
    pub message: Str<'a>,
    pub summary: Str<'a>,
}

pub(crate) fn parse(text: &str) -> Result<Wire<'_>, serde_json::Error> {
    let mut de = serde_json::Deserializer::from_str(text);
    let mut w = Wire::default();
    // A top-level non-object is no event: every required field is missing.
    de.deserialize_any(Root(&mut w))?;
    de.end()?;
    Ok(w)
}

/// Any JSON value, read through and dropped.
fn skip<'de, A: SeqAccess<'de>>(mut seq: A) -> Result<(), A::Error> {
    while seq.next_element::<IgnoredAny>()?.is_some() {}
    Ok(())
}

fn skip_map<'de, A: MapAccess<'de>>(mut map: A) -> Result<(), A::Error> {
    while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
    Ok(())
}

struct Key<'a>(Cow<'a, str>);

impl<'de> de::Deserialize<'de> for Key<'de> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_str(StrVisitor).map(|s| match s {
            Str::Text(t) => Key(t),
            _ => Key(Cow::Borrowed("")),
        })
    }
}

struct StrVisitor;

impl<'de> Visitor<'de> for StrVisitor {
    type Value = Str<'de>;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("any JSON value")
    }
    fn visit_borrowed_str<E>(self, v: &'de str) -> Result<Self::Value, E> {
        Ok(Str::Text(Cow::Borrowed(v)))
    }
    fn visit_str<E>(self, v: &str) -> Result<Self::Value, E> {
        Ok(Str::Text(Cow::Owned(v.to_owned())))
    }
    fn visit_string<E>(self, v: String) -> Result<Self::Value, E> {
        Ok(Str::Text(Cow::Owned(v)))
    }
    fn visit_bool<E>(self, _: bool) -> Result<Self::Value, E> {
        Ok(Str::Other)
    }
    fn visit_i64<E>(self, _: i64) -> Result<Self::Value, E> {
        Ok(Str::Other)
    }
    fn visit_u64<E>(self, _: u64) -> Result<Self::Value, E> {
        Ok(Str::Other)
    }
    fn visit_f64<E>(self, _: f64) -> Result<Self::Value, E> {
        Ok(Str::Other)
    }
    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(Str::Other)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, seq: A) -> Result<Self::Value, A::Error> {
        skip(seq).map(|_| Str::Other)
    }
    fn visit_map<A: MapAccess<'de>>(self, map: A) -> Result<Self::Value, A::Error> {
        skip_map(map).map(|_| Str::Other)
    }
}

impl<'de> de::Deserialize<'de> for Str<'de> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_any(StrVisitor)
    }
}

struct ScalarVisitor;

impl<'de> Visitor<'de> for ScalarVisitor {
    type Value = Scalar;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("any JSON value")
    }
    fn visit_bool<E>(self, v: bool) -> Result<Scalar, E> {
        Ok(Scalar::Bool(v))
    }
    fn visit_i64<E>(self, v: i64) -> Result<Scalar, E> {
        Ok(if v >= 0 { Scalar::U64(v as u64) } else { Scalar::I64(v) })
    }
    fn visit_u64<E>(self, v: u64) -> Result<Scalar, E> {
        Ok(Scalar::U64(v))
    }
    fn visit_f64<E>(self, _: f64) -> Result<Scalar, E> {
        Ok(Scalar::None)
    }
    fn visit_str<E>(self, _: &str) -> Result<Scalar, E> {
        Ok(Scalar::None)
    }
    fn visit_unit<E>(self) -> Result<Scalar, E> {
        Ok(Scalar::None)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, seq: A) -> Result<Scalar, A::Error> {
        skip(seq).map(|_| Scalar::None)
    }
    fn visit_map<A: MapAccess<'de>>(self, map: A) -> Result<Scalar, A::Error> {
        skip_map(map).map(|_| Scalar::None)
    }
}

impl<'de> de::Deserialize<'de> for Scalar {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_any(ScalarVisitor)
    }
}

struct InputVisitor;

impl<'de> Visitor<'de> for InputVisitor {
    type Value = ToolInput<'de>;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("any JSON value")
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut t = ToolInput::default();
        while let Some(Key(k)) = map.next_key()? {
            match &*k {
                "command" => t.command = map.next_value()?,
                "url" => t.url = map.next_value()?,
                "file_path" => t.file_path = map.next_value()?,
                _ => {
                    map.next_value::<IgnoredAny>()?;
                }
            }
        }
        Ok(t)
    }
    fn visit_bool<E>(self, _: bool) -> Result<Self::Value, E> {
        Ok(ToolInput::default())
    }
    fn visit_i64<E>(self, _: i64) -> Result<Self::Value, E> {
        Ok(ToolInput::default())
    }
    fn visit_u64<E>(self, _: u64) -> Result<Self::Value, E> {
        Ok(ToolInput::default())
    }
    fn visit_f64<E>(self, _: f64) -> Result<Self::Value, E> {
        Ok(ToolInput::default())
    }
    fn visit_str<E>(self, _: &str) -> Result<Self::Value, E> {
        Ok(ToolInput::default())
    }
    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(ToolInput::default())
    }
    fn visit_seq<A: SeqAccess<'de>>(self, seq: A) -> Result<Self::Value, A::Error> {
        skip(seq).map(|_| ToolInput::default())
    }
}

impl<'de> de::Deserialize<'de> for ToolInput<'de> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_any(InputVisitor)
    }
}

struct Root<'w, 'de>(&'w mut Wire<'de>);

impl<'de> Visitor<'de> for Root<'_, 'de> {
    type Value = ();
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("any JSON value")
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        let w = self.0;
        while let Some(Key(k)) = map.next_key()? {
            match &*k {
                "v" => w.v = map.next_value()?,
                "agent" => w.agent = map.next_value()?,
                "event" => w.event = map.next_value()?,
                "surface_id" => w.surface_id = map.next_value()?,
                "nonce" => w.nonce = map.next_value()?,
                "session_id" => w.session_id = map.next_value()?,
                "cwd" => w.cwd = map.next_value()?,
                "agent_id" => w.agent_id = map.next_value()?,
                "agent_type" => w.agent_type = map.next_value()?,
                "truncated" => w.truncated = map.next_value()?,
                "tool_name" => w.tool_name = map.next_value()?,
                "tool_use_id" => w.tool_use_id = map.next_value()?,
                "tool_input" => w.tool_input = map.next_value()?,
                "plugin_version" => w.plugin_version = map.next_value()?,
                "query" => w.query = map.next_value()?,
                "task_id" => w.task_id = map.next_value()?,
                "task_subject" => w.task_subject = map.next_value()?,
                "task_status" => w.task_status = map.next_value()?,
                "description" => w.description = map.next_value()?,
                "tool_count" => w.tool_count = map.next_value()?,
                "duration_ms" => w.duration_ms = map.next_value()?,
                "todos_done" => w.todos_done = map.next_value()?,
                "notification_type" => w.notification_type = map.next_value()?,
                "message" => w.message = map.next_value()?,
                "summary" => w.summary = map.next_value()?,
                _ => {
                    map.next_value::<IgnoredAny>()?;
                }
            }
        }
        Ok(())
    }
    fn visit_bool<E>(self, _: bool) -> Result<(), E> {
        Ok(())
    }
    fn visit_i64<E>(self, _: i64) -> Result<(), E> {
        Ok(())
    }
    fn visit_u64<E>(self, _: u64) -> Result<(), E> {
        Ok(())
    }
    fn visit_f64<E>(self, _: f64) -> Result<(), E> {
        Ok(())
    }
    fn visit_str<E>(self, _: &str) -> Result<(), E> {
        Ok(())
    }
    fn visit_unit<E>(self) -> Result<(), E> {
        Ok(())
    }
    fn visit_seq<A: SeqAccess<'de>>(self, seq: A) -> Result<(), A::Error> {
        skip(seq)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrong_types_are_absent_and_the_last_repeat_wins() {
        let w = parse(r#"{"v":1,"event":"a","event":"b","cwd":7,"agent":null,"tool_input":"x","tool_count":-1,"truncated":true,"x":[{"y":1}]}"#).unwrap();
        assert_eq!((w.v.as_i64(), w.event.text(), w.cwd.text(), w.agent == Str::Other), (Some(1), Some("b"), None, true));
        assert_eq!((w.tool_count.as_u64(), w.truncated.as_bool(), w.tool_input.command.text()), (None, Some(true), None));
        assert!(matches!(w.surface_id, Str::Absent));
        let w = parse(r#"{"tool_input":{"command":"a\nb","file_path":"/p"},"query":"plain"}"#).unwrap();
        assert!(matches!(w.query, Str::Text(Cow::Borrowed("plain"))), "unescaped strings are borrowed");
        assert_eq!((w.tool_input.command.text(), w.tool_input.file_path.text()), (Some("a\nb"), Some("/p")));
        assert!(parse("[1,2]").is_ok() && parse("{} x").is_err() && parse(r#"{"v":1"#).is_err());
    }
}
