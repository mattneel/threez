// Triangle example — first native WebGPU render (T20)
//
// Renders a colored triangle using the threez WebGPU polyfills.
// This file is loaded and eval'd by the threez runtime.
//
// The script exercises the full pipeline:
//   navigator.gpu.requestAdapter()
//   adapter.requestDevice()
//   canvas.getContext("webgpu").configure(...)
//   device.createShaderModule(...)
//   device.createRenderPipeline(...)
//   requestAnimationFrame loop:
//     getCurrentTexture -> createView -> beginRenderPass -> draw -> submit -> present

const shaderSource = `
struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) color: vec3f,
};

@vertex
fn vs_main(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
  var positions = array<vec2f, 3>(
    vec2f( 0.0,  0.5),
    vec2f(-0.5, -0.5),
    vec2f( 0.5, -0.5),
  );
  var colors = array<vec3f, 3>(
    vec3f(1.0, 0.0, 0.0),
    vec3f(0.0, 1.0, 0.0),
    vec3f(0.0, 0.0, 1.0),
  );

  var output: VertexOutput;
  output.position = vec4f(positions[vertexIndex], 0.0, 1.0);
  output.color = colors[vertexIndex];
  return output;
}

@fragment
fn fs_main(@location(0) color: vec3f) -> @location(0) vec4f {
  return vec4f(color, 1.0);
}
`;

async function main() {
  // 1. Request adapter and device
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    throw new Error("No GPU adapter found");
  }

  const device = await adapter.requestDevice();

  // 2. Set up the canvas and WebGPU context
  const canvas = document.createElement("canvas");
  const context = canvas.getContext("webgpu");
  const format = navigator.gpu.getPreferredCanvasFormat();

  context.configure({
    device: device,
    format: format,
  });

  // 3. Create the shader module
  const shaderModule = device.createShaderModule({
    code: shaderSource,
  });

  // 4. Create the render pipeline
  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: {
      module: shaderModule,
      entryPoint: "vs_main",
    },
    fragment: {
      module: shaderModule,
      entryPoint: "fs_main",
      targets: [{ format: format }],
    },
  });

  // 5. Render loop
  function frame() {
    // Get the current swap chain texture and create a view
    const texture = context.getCurrentTexture();
    const view = texture.createView();

    // Encode render commands
    const encoder = device.createCommandEncoder();
    const pass = encoder.beginRenderPass({
      colorAttachments: [{
        view: view,
        clearValue: { r: 0.1, g: 0.1, b: 0.2, a: 1.0 },
        loadOp: "clear",
        storeOp: "store",
      }],
    });

    pass.setPipeline(pipeline);
    pass.draw(3);
    pass.end();

    // Submit and present
    device.queue.submit([encoder.finish()]);
    context.present();

    // Schedule next frame
    requestAnimationFrame(frame);
  }

  requestAnimationFrame(frame);
}

main().catch(function(e) {
  console.error("Triangle error:", e);
});
