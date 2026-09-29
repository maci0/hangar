/**
 * Encoded video overlay (H.264 over `/ws/video/<n>`, see docs/VIDEO-PIPELINE.md). When the VM has
 * `video_stream` and the browser has `VideoDecoder`, decoded frames paint onto a canvas layered over
 * the client canvas. The layer ignores the pointer, so input still reaches the client below it. When
 * anything goes wrong the layer is dropped and the client canvas is what the user sees.
 */
import { relayUrl } from "@/lib/console";
import type { Vm } from "@/lib/vm";

export type VideoHost = {
  /** Index of the selected VM in the list, or null. */
  readonly selected: () => number | null;
  readonly vmAt: (index: number) => Vm | undefined;
};

export type VideoStream = {
  /** Opens the stream of the VM at `index` if it has one and the browser can decode it. */
  readonly start: (index: number) => void;
  /** Closes the socket and the decoder and removes the layer. */
  readonly stop: () => void;
  /** Frames are being painted. */
  readonly painting: () => boolean;
};

const RETRY_MAX = 5;
const RETRY_MS = 2000;
// One frame at 30 fps, in microseconds.
const FRAME_US = 33_333;
const CODEC = "avc1.42E01F";
const MESSAGE_CONFIG = 1;
const MESSAGE_DELTA = 2;
const MESSAGE_KEY = 3;
const LITTLE_ENDIAN = true;
const WIDTH_OFFSET = 1;
const HEIGHT_OFFSET = 3;

type Timer = ReturnType<typeof setTimeout>;

type Stream = {
  readonly host: VideoHost;
  readonly surface: () => HTMLElement | null;
  readonly onPainting: (painting: boolean) => void;
  socket: WebSocket | null;
  canvas: HTMLCanvasElement | null;
  decoder: VideoDecoder | null;
  timestamp: number;
  retries: number;
  retryTimer: Timer | null;
  /** Starts again without resetting the retry count (the retry timer calls it). */
  readonly restart: (index: number) => void;
};

const stopStream = (stream: Stream): void => {
  if (stream.retryTimer !== null) {
    clearTimeout(stream.retryTimer);
    stream.retryTimer = null;
  }
  stream.socket?.close();
  stream.socket = null;
  if (stream.decoder !== null && stream.decoder.state !== "closed") {
    stream.decoder.close();
  }
  stream.decoder = null;
  stream.canvas?.remove();
  stream.canvas = null;
  stream.timestamp = 0;
  stream.onPainting(false);
};

/** Config message: u8 type, u16 width, u16 height, u8 codec, little endian. */
const onConfig = (stream: Stream, message: Uint8Array): void => {
  const surface = stream.surface();
  if (surface === null) {
    return;
  }
  const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
  if (stream.canvas === null) {
    stream.canvas = document.createElement("canvas");
    stream.canvas.className = "video-layer";
    surface.append(stream.canvas);
  }
  const { canvas } = stream;
  canvas.width = view.getUint16(WIDTH_OFFSET, LITTLE_ENDIAN);
  canvas.height = view.getUint16(HEIGHT_OFFSET, LITTLE_ENDIAN);
  const decoder = new VideoDecoder({
    output: (frame) => {
      canvas.getContext("2d")?.drawImage(frame, 0, 0);
      frame.close();
    },
    error: () => {
      stopStream(stream);
    },
  });
  decoder.configure({ codec: CODEC, optimizeForLatency: true, hardwareAcceleration: "no-preference" });
  stream.decoder = decoder;
  stream.onPainting(true);
};

const onFrame = (stream: Stream, message: Uint8Array): void => {
  const { decoder } = stream;
  if (decoder?.state !== "configured") {
    return;
  }
  const key = message[0] === MESSAGE_KEY;
  // Nothing decodes before the first key frame.
  if (stream.timestamp === 0 && !key) {
    return;
  }
  stream.timestamp += FRAME_US;
  decoder.decode(new EncodedVideoChunk({ type: key ? "key" : "delta", timestamp: stream.timestamp, data: message.subarray(1) }));
};

const onMessage = (stream: Stream, message: Uint8Array): void => {
  if (message[0] === MESSAGE_CONFIG) {
    onConfig(stream, message);
  } else if (message[0] === MESSAGE_DELTA || message[0] === MESSAGE_KEY) {
    onFrame(stream, message);
  }
};

const openStream = (stream: Stream, index: number): void => {
  const socket = new WebSocket(relayUrl(location, "video", index));
  socket.binaryType = "arraybuffer";
  stream.socket = socket;
  socket.addEventListener("message", (event: MessageEvent<ArrayBuffer>) => {
    onMessage(stream, new Uint8Array(event.data));
  });
  socket.addEventListener("error", () => {
    if (stream.socket === socket) {
      stopStream(stream);
    }
  });
  socket.addEventListener("close", () => {
    if (stream.socket !== socket) {
      return;
    }
    const hadConfig = stream.decoder !== null;
    stopStream(stream);
    // An early close (connected before the capture session was up) is retried a few times while the VM runs.
    const { host } = stream;
    if (!hadConfig && stream.retries < RETRY_MAX && host.selected() === index && host.vmAt(index)?.status === "running") {
      stream.retries += 1;
      stream.retryTimer = setTimeout(() => {
        stream.retryTimer = null;
        stream.restart(index);
      }, RETRY_MS);
    }
  });
};

const startStream = (stream: Stream, index: number): void => {
  if (stream.socket !== null || typeof VideoDecoder === "undefined") {
    return;
  }
  if (stream.host.vmAt(index)?.video_stream !== "true" || stream.surface() === null) {
    return;
  }
  openStream(stream, index);
};

export const createVideoStream = (
  host: VideoHost,
  surface: () => HTMLElement | null,
  onPainting: (painting: boolean) => void,
): VideoStream => {
  const stream: Stream = {
    host,
    surface,
    onPainting,
    socket: null,
    canvas: null,
    decoder: null,
    timestamp: 0,
    retries: 0,
    retryTimer: null,
    restart: (index) => {
      startStream(stream, index);
    },
  };
  return {
    start: (index) => {
      stream.retries = 0;
      startStream(stream, index);
    },
    stop: () => {
      stopStream(stream);
    },
    painting: () => stream.canvas !== null,
  };
};
