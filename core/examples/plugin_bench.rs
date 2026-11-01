//! Cold vs cached load of a plugin component: `plugin_bench <wasm> <cache-dir>`.

use std::time::Instant;

use haunt_core::plugins::PluginHost;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (wasm, cache) = (std::path::Path::new(&args[1]), std::path::Path::new(&args[2]));
    let t = Instant::now();
    let host = PluginHost::new().unwrap();
    println!("engine_new_ms={:.2}", t.elapsed().as_secs_f64() * 1e3);
    let (mut p, stats) = host.load(wasm, cache).unwrap();
    println!("{stats:?}");
    let ev = haunt_core::parse_osc(
        "warp://cli-agent",
        r#"{"v":1,"agent":"claude","session_id":"s","event":"task_created","task_id":"1","task_subject":"step 1"}"#,
    )
    .unwrap();
    let t = Instant::now();
    let d = p.on_event(&ev, false).unwrap();
    println!("on_event_us={:.1} decoration={d:?} logs={:?}", t.elapsed().as_secs_f64() * 1e6, p.take_logs());
}
