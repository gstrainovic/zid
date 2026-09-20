// SVG-Atlas-Shader — Symbole als Maske aus einem Einkanal-Atlas, eingefärbt
// über die Vertexfarbe. Früher teilte sich die SVG-Schicht den Text-Shader;
// seit der Text zusätzlich farbige Emoji zeichnet, braucht der Text ein
// weiteres Vertexfeld und eine zweite Textur, die Symbole nicht.
struct VertexInput {
    @location(0) pos: vec2f,
    @location(1) uv: vec2f,
    @location(2) color: vec4f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) uv: vec2f,
    @location(1) color: vec4f,
}

@group(0) @binding(0)
var svg_atlas: texture_2d<f32>;
@group(0) @binding(1)
var svg_sampler: sampler;

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = vec4f(input.pos, 0.0, 1.0);
    out.uv = input.uv;
    out.color = input.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let alpha = textureSample(svg_atlas, svg_sampler, in.uv).r;
    return vec4f(in.color.rgb, in.color.a * alpha);
}
