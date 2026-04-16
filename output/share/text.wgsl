// Text rendering shader - rendert Glyphen aus Atlas-Textur
struct VertexInput {
    @location(0) pos: vec2f,
    @location(1) uv: vec2f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) uv: vec2f,
}

@group(0) @binding(0)
var glyph_atlas: texture_2d<f32>;
@group(0) @binding(1)
var glyph_sampler: sampler;

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = vec4f(input.pos, 0.0, 1.0);
    out.uv = input.uv;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let glyph_color = textureSample(glyph_atlas, glyph_sampler, in.uv);
    // Weisser Text mit Alpha aus Atlas
    return vec4f(1.0, 1.0, 1.0, glyph_color.a);
}
