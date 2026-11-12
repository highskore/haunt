#if HAUNT_REAL_CORE
import Foundation

/// `LoadedTheme.layerParser` in the app: core checks and caps the chain's layers and decodes their PNGs.
let coreLayerParser: ([(name: String, toml: String, files: [(String, Data)])]) -> (LayerSource, [String]) = { chain in
    let set = themeLayers(chain: chain.map { ThemeSource(name: $0.name, toml: $0.toml, files: $0.files.map { ThemeFile(name: $0.0, bytes: $0.1) }) })
    func span(_ s: LayerSpan) -> SpanSpec { SpanSpec(mode: s.mode, a: s.a, b: s.b, fromText: s.fromText) }
    let specs = set.layers.map { l in
        LayerSpec(id: l.id, slot: l.slot, when: l.when, opacity: l.opacity, index: l.index.map(Int.init), prims: l.prims.map { p in
            PrimSpec(kind: p.kind, x: span(p.x), y: span(p.y), radius: p.radius, fill: p.fill, stroke: p.stroke, width: p.width, dash: p.dash,
                     along: p.along, angle: p.angle, stops: p.stops.map { .init(color: $0.color, at: $0.at) }, rings: p.rings, cell: p.cell,
                     dots: zip(p.dots, p.dotY).map { .init(color: $0.color, x: $0.at, y: $1) }, image: p.image.map(Int.init),
                     repeatMode: p.repeatMode, path: p.path.map { .init(op: $0.op, pts: $0.pts) }, view: p.view, blur: p.blur,
                     offset: p.offset, color: p.color)
        })
    }
    let images = set.images.map { LayerSource.Image(name: $0.name, data: $0.rgba, width: Int($0.width), height: Int($0.height)) }
    return (LayerSource(specs: specs, images: images), set.problems)
}
#endif
