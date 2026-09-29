/**
 * GPU presenter for the display. The client (noVNC or SPICE) paints its own canvas; the presenter
 * copies that canvas into a WebGPU (or WebGL) canvas every frame. The client canvas stays on top,
 * invisible, so pointer and keyboard input still reach it. With no GPU API the client canvas is shown
 * as is (`canvas`).
 */
import type { Renderer } from "@/lib/console";

export type Presenter = { readonly stop: () => void };

const PRESENTER_CLASS = "gpu-presenter";
const SOURCE_CLASS = "display-source-canvas";
const VERTICES_PER_QUAD = 6;
const FLOATS_PER_VERTEX = 4;
const BYTES_PER_FLOAT = 4;
const UV_OFFSET_BYTES = 8;
const POSITION_SIZE = 2;

const WGSL = `struct Out { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) i: u32) -> Out {
  var pos = array<vec2<f32>, 6>(vec2<f32>(-1.0,-1.0), vec2<f32>(1.0,-1.0), vec2<f32>(-1.0,1.0), vec2<f32>(-1.0,1.0), vec2<f32>(1.0,-1.0), vec2<f32>(1.0,1.0));
  var uv = array<vec2<f32>, 6>(vec2<f32>(0.0,1.0), vec2<f32>(1.0,1.0), vec2<f32>(0.0,0.0), vec2<f32>(0.0,0.0), vec2<f32>(1.0,1.0), vec2<f32>(1.0,0.0));
  var out: Out; out.pos = vec4<f32>(pos[i], 0.0, 1.0); out.uv = uv[i]; return out;
}
@group(0) @binding(0) var frameTex: texture_2d<f32>;
@group(0) @binding(1) var frameSampler: sampler;
@fragment fn fs(in: Out) -> @location(0) vec4<f32> { return textureSample(frameTex, frameSampler, in.uv); }
`;

const VERTEX_SHADER = "attribute vec2 aPos;attribute vec2 aUv;varying vec2 vUv;void main(){vUv=aUv;gl_Position=vec4(aPos,0.0,1.0);}";
const FRAGMENT_SHADER = "precision mediump float;varying vec2 vUv;uniform sampler2D uTex;void main(){gl_FragColor=texture2D(uTex,vUv);}";

// Two triangles covering the canvas: x, y, u, v per vertex.
const QUAD = new Float32Array([-1, -1, 0, 0, 1, -1, 1, 0, -1, 1, 0, 1, -1, 1, 0, 1, 1, -1, 1, 0, 1, 1, 1, 1]);
const GL_OPTIONS: WebGLContextAttributes = { alpha: false, antialias: false };

type Session = {
  readonly surface: HTMLElement;
  readonly onMode: (mode: Renderer) => void;
  stopped: boolean;
  raf: number;
  canvas: HTMLCanvasElement | null;
};

/** The client's canvas: the first one in the surface that is not the presenter's. */
const findSourceCanvas = (surface: HTMLElement): HTMLCanvasElement | null => {
  for (const canvas of surface.querySelectorAll("canvas")) {
    if (!canvas.classList.contains(PRESENTER_CLASS)) {
      return canvas;
    }
  }
  return null;
};

/** The client canvas once it has a size, marked so the stylesheet keeps it on top and invisible. */
const readySource = (session: Session): HTMLCanvasElement | null => {
  const source = findSourceCanvas(session.surface);
  if (source === null || source.width === 0 || source.height === 0) {
    return null;
  }
  source.classList.add(SOURCE_CLASS);
  return source;
};

const matchSize = (target: HTMLCanvasElement, source: HTMLCanvasElement): boolean => {
  if (target.width === source.width && target.height === source.height) {
    return false;
  }
  target.width = source.width;
  target.height = source.height;
  return true;
};

const ensureCanvas = (session: Session): HTMLCanvasElement => {
  if (session.canvas !== null) {
    return session.canvas;
  }
  const canvas = document.createElement("canvas");
  canvas.className = PRESENTER_CLASS;
  canvas.setAttribute("aria-hidden", "true");
  session.surface.append(canvas);
  session.canvas = canvas;
  return canvas;
};

const dropCanvas = (session: Session): void => {
  session.canvas?.remove();
  session.canvas = null;
};

const showClientCanvas = (session: Session): void => {
  dropCanvas(session);
  session.onMode("canvas");
};

type GpuFrame = { readonly width: number; readonly height: number; readonly texture: GPUTexture; readonly group: GPUBindGroup };

type GpuPipeline = {
  readonly device: GPUDevice;
  readonly context: GPUCanvasContext;
  readonly sampler: GPUSampler;
  readonly layout: GPUBindGroupLayout;
  readonly pipeline: GPURenderPipeline;
};

const buildGpuPipeline = (device: GPUDevice, context: GPUCanvasContext): GpuPipeline => {
  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "opaque" });
  const shader = device.createShaderModule({ code: WGSL });
  const layout = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: GPUShaderStage.FRAGMENT, texture: {} },
      { binding: 1, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
    ],
  });
  const pipeline = device.createRenderPipeline({
    layout: device.createPipelineLayout({ bindGroupLayouts: [layout] }),
    vertex: { module: shader, entryPoint: "vs" },
    fragment: { module: shader, entryPoint: "fs", targets: [{ format }] },
    primitive: { topology: "triangle-list" },
  });
  const sampler = device.createSampler({ magFilter: "linear", minFilter: "linear" });
  return { device, context, sampler, layout, pipeline };
};

const createGpuFrame = (gpu: GpuPipeline, source: HTMLCanvasElement): GpuFrame => {
  // The two usage flags are distinct bits, so adding them is the same as OR-ing them.
  const texture = gpu.device.createTexture({
    size: [source.width, source.height, 1],
    format: "rgba8unorm",
    usage: GPUTextureUsage.TEXTURE_BINDING + GPUTextureUsage.COPY_DST,
  });
  const group = gpu.device.createBindGroup({
    layout: gpu.layout,
    entries: [
      { binding: 0, resource: texture.createView() },
      { binding: 1, resource: gpu.sampler },
    ],
  });
  return { width: source.width, height: source.height, texture, group };
};

const drawGpuFrame = (gpu: GpuPipeline, frame: GpuFrame, source: HTMLCanvasElement): void => {
  const { device } = gpu;
  device.queue.copyExternalImageToTexture({ source }, { texture: frame.texture }, { width: source.width, height: source.height });
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginRenderPass({
    colorAttachments: [
      {
        view: gpu.context.getCurrentTexture().createView(),
        clearValue: { r: 0, g: 0, b: 0, a: 1 },
        loadOp: "clear",
        storeOp: "store",
      },
    ],
  });
  pass.setPipeline(gpu.pipeline);
  pass.setBindGroup(0, frame.group);
  pass.draw(VERTICES_PER_QUAD);
  pass.end();
  device.queue.submit([encoder.finish()]);
};

const runGpuLoop = (session: Session, canvas: HTMLCanvasElement, gpu: GpuPipeline): void => {
  let frame: GpuFrame | null = null;
  const tick = (): void => {
    if (session.stopped) {
      return;
    }
    const source = readySource(session);
    if (source !== null) {
      matchSize(canvas, source);
      if (frame === null || frame.width !== source.width || frame.height !== source.height) {
        frame = createGpuFrame(gpu, source);
      }
      drawGpuFrame(gpu, frame, source);
    }
    session.raf = requestAnimationFrame(tick);
  };
  tick();
};

const initWebGpu = async (session: Session): Promise<void> => {
  const adapter = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
  if (adapter === null) {
    throw new Error("WebGPU adapter unavailable");
  }
  const device = await adapter.requestDevice();
  if (session.stopped) {
    return;
  }
  const canvas = ensureCanvas(session);
  const context = canvas.getContext("webgpu");
  if (context === null) {
    throw new Error("WebGPU canvas unavailable");
  }
  const gpu = buildGpuPipeline(device, context);
  session.onMode("webgpu");
  runGpuLoop(session, canvas, gpu);
};

const compile = (gl: WebGLRenderingContext, type: number, source: string): WebGLShader | null => {
  const shader = gl.createShader(type);
  if (shader === null) {
    return null;
  }
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  return gl.getShaderParameter(shader, gl.COMPILE_STATUS) === true ? shader : null;
};

/** The quad program, or null when this GPU cannot compile or link it. */
const linkQuadProgram = (gl: WebGLRenderingContext): WebGLProgram | null => {
  const vertex = compile(gl, gl.VERTEX_SHADER, VERTEX_SHADER);
  const fragment = compile(gl, gl.FRAGMENT_SHADER, FRAGMENT_SHADER);
  if (vertex === null || fragment === null) {
    return null;
  }
  const program = gl.createProgram();
  for (const shader of [vertex, fragment]) {
    gl.attachShader(program, shader);
  }
  gl.linkProgram(program);
  return gl.getProgramParameter(program, gl.LINK_STATUS) === true ? program : null;
};

const bindQuad = (gl: WebGLRenderingContext, program: WebGLProgram): void => {
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, QUAD, gl.STATIC_DRAW);
  const stride = FLOATS_PER_VERTEX * BYTES_PER_FLOAT;
  const position = gl.getAttribLocation(program, "aPos");
  const uv = gl.getAttribLocation(program, "aUv");
  gl.enableVertexAttribArray(position);
  gl.vertexAttribPointer(position, POSITION_SIZE, gl.FLOAT, false, stride, 0);
  gl.enableVertexAttribArray(uv);
  gl.vertexAttribPointer(uv, POSITION_SIZE, gl.FLOAT, false, stride, UV_OFFSET_BYTES);
};

const bindTexture = (gl: WebGLRenderingContext): WebGLTexture => {
  const texture = gl.createTexture();
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
  return texture;
};

const runGlLoop = (session: Session, canvas: HTMLCanvasElement, gl: WebGLRenderingContext, texture: WebGLTexture): void => {
  const tick = (): void => {
    if (session.stopped) {
      return;
    }
    const source = readySource(session);
    if (source !== null) {
      if (matchSize(canvas, source)) {
        gl.viewport(0, 0, canvas.width, canvas.height);
      }
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
      gl.drawArrays(gl.TRIANGLES, 0, VERTICES_PER_QUAD);
    }
    session.raf = requestAnimationFrame(tick);
  };
  tick();
};

const initWebGl = (session: Session): void => {
  const canvas = ensureCanvas(session);
  const gl2 = canvas.getContext("webgl2", GL_OPTIONS);
  const gl: WebGLRenderingContext | null = gl2 ?? canvas.getContext("webgl", GL_OPTIONS);
  const program = gl === null ? null : linkQuadProgram(gl);
  if (gl === null || program === null) {
    showClientCanvas(session);
    return;
  }
  gl.useProgram(program);
  bindQuad(gl, program);
  const texture = bindTexture(gl);
  session.onMode(gl2 === null ? "webgl" : "webgl2");
  runGlLoop(session, canvas, gl, texture);
};

/**
 * Starts presenting the surface's client canvas. `onMode` reports the renderer once it is chosen:
 * `webgpu`, `webgl2`, `webgl`, or `canvas` when no GPU path works.
 */
export const startPresenter = (surface: HTMLElement, onMode: (mode: Renderer) => void): Presenter => {
  const session: Session = { surface, onMode, stopped: false, raf: 0, canvas: null };
  if ("gpu" in navigator) {
    initWebGpu(session).catch(() => {
      if (!session.stopped) {
        initWebGl(session);
      }
    });
  } else {
    initWebGl(session);
  }
  return {
    stop: () => {
      session.stopped = true;
      cancelAnimationFrame(session.raf);
      dropCanvas(session);
      for (const source of surface.querySelectorAll(`.${SOURCE_CLASS}`)) {
        source.classList.remove(SOURCE_CLASS);
      }
    },
  };
};
