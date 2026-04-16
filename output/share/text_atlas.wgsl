// Text Atlas Shader - rendert Glyphen aus Atlas-Textur
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
var glyph_atlas: texture_2d<f32>;
@group(0) @binding(1)
var glyph_sampler: sampler;

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
    // Sample atlas (grayscale)
    let alpha = textureSample(glyph_atlas, glyph_sampler, in.uv).r;
    // Text color with atlas alpha mask
    return vec4f(in.color.rgb, in.color.a * alpha);
}
