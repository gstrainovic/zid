// Textured Quad Shader für Image Rendering
// Rendert ein Textured Quad mit optionaler Tint-Farbe und Opacity

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
}

@vertex
fn vs_main(
    @location(0) position: vec2<f32>,
    @location(1) tex_coord: vec2<f32>,
    @location(2) color: vec4<f32>,
) -> VertexOutput {
    var output: VertexOutput;
    output.clip_position = vec4<f32>(position, 0.0, 1.0);
    output.uv = tex_coord;
    output.color = color;
    return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    // Sample texture (wird via Bind Group bereitgestellt)
    let tex_color = textureSample(image_texture, image_sampler, input.uv);
    
    // Apply Tint/Color
    let final_color = vec4<f32>(
        tex_color.rgb * input.color.rgb,
        tex_color.a * input.color.a
    );
    
    if final_color.a < 0.001 { discard; }
    
    return final_color;
}

// Texture und Sampler Bindings
@group(0) @binding(0) var image_texture: texture_2d<f32>;
@group(0) @binding(1) var image_sampler: sampler;
