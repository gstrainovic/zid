// Text rendering shader - rendert Glyphen aus Atlas-Textur
struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

@vertex
fn vs_main(
    @location(0) pos: vec2f,
    @location(1) uv: vec2f,
) -> VertexOutput {
    var out: VertexOutput;
    out.position = vec4f(pos, 0.0, 1.0);
    out.uv = uv;
    return out;
}

@group(0) @binding(0)
var glyph_atlas: texture_2d<f32>;
@group(0) @binding(1)
var glyph_sampler: sampler;

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let glyph_color = textureSample(glyph_atlas, glyph_sampler, in.uv);
    // Weißer Text mit Alpha aus Atlas
    return vec4f(1.0, 1.0, 1.0, glyph_color.a);
}
