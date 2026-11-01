//! wasmtime host for `haunt:plugin@0.1` components. Phase 0: one plugin, no capabilities.

use std::hash::{Hash, Hasher};
use std::path::Path;
use std::time::Instant;

use wasmtime::component::{Component, HasSelf, Linker};
use wasmtime::component::ResourceTable;
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxView, WasiView};

use crate::event::{AgentEvent, EventKind};

mod bindings {
    wasmtime::component::bindgen!({ path: "../wit/haunt-plugin.wit", world: "plugin" });
}

use bindings::haunt::plugin::types as wit;
use bindings::{Plugin, PluginImports};

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Decoration {
    pub badge: Option<String>,
    pub style: String,
    pub meta_suffix: Option<String>,
}

#[derive(Debug, Clone, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct LoadStats {
    pub wasm_bytes: u64,
    pub from_cache: bool,
    pub compile_ms: f64,
    pub instantiate_ms: f64,
}

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct PluginError(pub String);

impl From<wasmtime::Error> for PluginError {
    fn from(e: wasmtime::Error) -> Self {
        Self(format!("{e:#}"))
    }
}
impl From<std::io::Error> for PluginError {
    fn from(e: std::io::Error) -> Self {
        Self(e.to_string())
    }
}

pub struct HostState {
    logs: Vec<String>,
    wasi: WasiCtx,
    table: ResourceTable,
}

// wasm32-wasip2 std imports WASI; the context grants nothing (no dirs, env, sockets).
impl WasiView for HostState {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl PluginImports for HostState {
    fn log(&mut self, msg: String) {
        self.logs.push(msg);
    }
}

impl wit::Host for HostState {}

pub struct LoadedPlugin {
    store: Store<HostState>,
    bindings: Plugin,
}

impl LoadedPlugin {
    pub fn on_event(&mut self, event: &AgentEvent) -> Result<Option<Decoration>, PluginError> {
        let summary = match &event.kind {
            EventKind::TaskCreated { subject, .. } => subject.clone(),
            EventKind::TaskUpdated { status, .. } => Some(status.clone()),
            EventKind::ToolRan { tool_name, .. } | EventKind::SubagentTool { tool_name } => Some(tool_name.clone()),
            _ => None,
        };
        let ev = wit::AgentEvent {
            kind: event.kind.name().to_owned(),
            session_id: event.session_id.clone(),
            agent_id: event.agent_id.clone(),
            cwd: event.cwd.clone(),
            summary,
        };
        let out = self.bindings.call_on_event(&mut self.store, &ev)?;
        Ok(out.map(|d| Decoration {
            badge: d.badge,
            style: match d.style {
                wit::Style::Meta => "meta",
                wit::Style::Needs => "needs",
                wit::Style::Dot => "dot",
                wit::Style::HollowDot => "hollow-dot",
                wit::Style::Kbd => "kbd",
                wit::Style::Mono => "mono",
            }
            .to_owned(),
            meta_suffix: d.meta_suffix,
        }))
    }

    pub fn take_logs(&mut self) -> Vec<String> {
        std::mem::take(&mut self.store.data_mut().logs)
    }
}

pub struct PluginHost {
    engine: Engine,
}

impl PluginHost {
    pub fn new() -> Result<Self, PluginError> {
        let mut config = Config::new();
        config.wasm_component_model(true);
        Ok(Self { engine: Engine::new(&config)? })
    }

    /// Loads a component, reusing a serialised compile from `cache_dir` when present.
    pub fn load(&self, wasm: &Path, cache_dir: &Path) -> Result<(LoadedPlugin, LoadStats), PluginError> {
        let bytes = std::fs::read(wasm)?;
        let mut h = std::collections::hash_map::DefaultHasher::new();
        bytes.hash(&mut h);
        self.engine.precompile_compatibility_hash().hash(&mut h);
        let cached = cache_dir.join(format!("{:016x}.cwasm", h.finish()));

        let t = Instant::now();
        let from_cache = cached.exists();
        let component = if from_cache {
            // Safety: the file is one we serialised for this engine; the name is keyed on its config hash.
            unsafe { Component::deserialize_file(&self.engine, &cached)? }
        } else {
            let c = Component::new(&self.engine, &bytes)?;
            std::fs::create_dir_all(cache_dir)?;
            std::fs::write(&cached, c.serialize()?)?;
            c
        };
        let compile_ms = t.elapsed().as_secs_f64() * 1e3;

        let t = Instant::now();
        let mut linker = Linker::<HostState>::new(&self.engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
        Plugin::add_to_linker::<_, HasSelf<_>>(&mut linker, |s| s)?;
        let state = HostState { logs: Vec::new(), wasi: WasiCtx::builder().build(), table: ResourceTable::new() };
        let mut store = Store::new(&self.engine, state);
        let bindings = Plugin::instantiate(&mut store, &component, &linker)?;
        let instantiate_ms = t.elapsed().as_secs_f64() * 1e3;

        Ok((
            LoadedPlugin { store, bindings },
            LoadStats { wasm_bytes: bytes.len() as u64, from_cache, compile_ms, instantiate_ms },
        ))
    }
}
