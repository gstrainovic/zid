// Text Atlas Shader - rendert Glyphen aus Atlas-Textur
struct VertexInput {
    @location(0) pos: vec2f,
    @location(1) uv: vec2f,
    @location(2) color: vec4f,
    // 1 = Emoji aus dem Farbatlas, 0 = Maske aus dem Textatlas
    @location(3) is_color: f32,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) uv: vec2f,
    @location(1) color: vec4f,
    @location(2) is_color: f32,
}

@group(0) @binding(0)
var glyph_atlas: texture_2d<f32>;
@group(0) @binding(1)
var glyph_sampler: sampler;
@group(0) @binding(2)
var emoji_atlas: texture_2d<f32>;

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = vec4f(input.pos, 0.0, 1.0);
    out.uv = input.uv;
    out.color = input.color;
    out.is_color = input.is_color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    // Textglyph: Atlas liefert nur die Deckung, die Farbe kommt vom Vertex.
    let alpha = textureSample(glyph_atlas, glyph_sampler, in.uv).r;
    let masked = vec4f(in.color.rgb, in.color.a * alpha);

    // Emoji: der Atlas liefert die fertigen Farben, die Textfarbe zählt nicht.
    let emoji = textureSample(emoji_atlas, glyph_sampler, in.uv);
    let tinted = vec4f(emoji.rgb, emoji.a * in.color.a);

    return mix(masked, tinted, in.is_color);
}
