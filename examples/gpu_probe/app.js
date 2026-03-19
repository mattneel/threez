// Looping GPU probe — mirrors triangle example to find crash frame
console.log("PROBE: script start");

async function probe() {
  const adapter = await navigator.gpu.requestAdapter();
  const device = await adapter.requestDevice();
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('webgpu');
  const format = navigator.gpu.getPreferredCanvasFormat();
  console.log("PROBE: format=" + format);

  ctx.configure({ device: device, format: format });

  const shaderModule = device.createShaderModule({
    code: `
      struct VertexOutput {
        @builtin(position) position: vec4f,
        @location(0) color: vec3f,
      };
      @vertex fn vs_main(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
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
      @fragment fn fs_main(@location(0) color: vec3f) -> @location(0) vec4f {
        return vec4f(color, 1.0);
      }
    `
  });
  console.log("PROBE: shader created");

  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: shaderModule, entryPoint: "vs_main" },
    fragment: { module: shaderModule, entryPoint: "fs_main", targets: [{ format: format }] },
  });
  console.log("PROBE: pipeline created");

  var frameCount = 0;

  function frame() {
    frameCount++;
    try {
      var texture = ctx.getCurrentTexture();
      var view = texture.createView();
      var encoder = device.createCommandEncoder();
      var pass = encoder.beginRenderPass({
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
      device.queue.submit([encoder.finish()]);
      ctx.present();

    } catch (e) {
      console.log("PROBE ERROR frame " + frameCount + ": " + e.message);
      console.log("PROBE STACK: " + (e.stack || "no stack"));
      return; // stop looping on error
    }

    requestAnimationFrame(frame);
    if (frameCount % 100 === 0) {
      console.log("PROBE: milestone frame " + frameCount);
    }
  }

  requestAnimationFrame(frame);
}

probe().catch(function(e) {
  console.log("PROBE INIT ERROR: " + e.message);
});
