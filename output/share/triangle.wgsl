// Dreieck Shader (WGSL) – bunt, mit vertex_index, kein Vertex Buffer nötig

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec3<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var pos = vec2<f32>(0.0, 0.0);
    var col = vec3<f32>(1.0, 1.0, 1.0);

    if (vertex_index == 0u) {
        pos = vec2<f32>(0.0, 0.5);
        col = vec3<f32>(1.0, 0.0, 0.0); // Rot – oben
    } else if (vertex_index == 1u) {
        pos = vec2<f32>(-0.5, -0.5);
        col = vec3<f32>(0.0, 1.0, 0.0); // Grün – links unten
    } else {
        pos = vec2<f32>(0.5, -0.5);
        col = vec3<f32>(0.0, 0.5, 1.0); // Blau – rechts unten
    }

    var output: VertexOutput;
    output.clip_position = vec4<f32>(pos, 0.0, 1.0);
    output.color = col;
    return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    return vec4<f32>(input.color, 1.0);
}
