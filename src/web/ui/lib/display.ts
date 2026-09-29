/**
 * The embedded display: noVNC or SPICE mounted into the Preact-owned `#display` element, a GPU
 * presenter over it, the optional H.264 overlay, and reconnect. The controller owns the clients and
 * the timers and publishes a `DisplayState` after every change; the component only draws it.
 */
import { ensureAsset } from "@/lib/assets";
import {
  badgeLabel,
  DISPLAY_RECONNECT_MAX_MS,
  nextDelay,
  RECONNECT_BASE_MS,
  relayUrl,
  VIDEO_BADGE,
  type BadgeKind,
  type Protocol,
  type Renderer,
} from "@/lib/console";
import { startPresenter, type Presenter } from "@/lib/presenter";
import type { RfbClient, RfbConstructor, SpiceConnection } from "@/lib/vendor";
import { createVideoStream, type VideoHost, type VideoStream } from "@/lib/video";
import { DISPLAY_LABELS, embeddedDisplayCapable, SPICE_DISPLAY, VNC_DISPLAY, type Vm } from "@/lib/vm";

/** What the display asks of the session: the selection, and a place to report what went wrong. */
export type DisplayHost = VideoHost & {
  readonly log: (message: string, detail: unknown) => void;
};

/** The message over the display. */
export type DisplayHint =
  | { readonly kind: "none" }
  | { readonly kind: "loading"; readonly client: string }
  | { readonly kind: "failed"; readonly client: string }
  | { readonly kind: "native"; readonly label: string };

export type DisplayState = {
  /** The display box is shown (a console client is starting or running). */
  readonly visible: boolean;
  /** Spinner while the client connects. */
  readonly loading: boolean;
  readonly connected: boolean;
  /** `native` for a display QEMU draws itself; a presenter mode once one is chosen. */
  readonly renderer: Renderer | "native" | null;
  /** The H.264 overlay is painting. */
  readonly video: boolean;
  readonly badge: string;
  readonly protocol: Protocol | null;
  readonly hint: DisplayHint;
};

export const IDLE_DISPLAY: DisplayState = {
  visible: false,
  loading: false,
  connected: false,
  renderer: null,
  video: false,
  badge: "",
  protocol: null,
  hint: { kind: "none" },
};

export type DisplayController = {
  /** Gives the controller the element the clients mount into; null when it goes away. */
  readonly attach: (element: HTMLElement | null) => void;
  /** Opens the display of the selected VM if it is running; no-op while a client exists. */
  readonly start: () => void;
  /** Closes the clients and hides the display. */
  readonly stop: () => void;
  /** Stops, then starts again; also the Retry after a client failed to load. */
  readonly reconnect: () => void;
  /** A client exists (connecting or connected). */
  readonly hasClient: () => boolean;
};

const NO_HINT: DisplayHint = { kind: "none" };
const NATIVE_LABEL_UNKNOWN = "QEMU";

type Timer = ReturnType<typeof setTimeout>;

type Display = {
  readonly host: DisplayHost;
  readonly publish: (state: DisplayState) => void;
  readonly video: VideoStream;
  surface: HTMLElement | null;
  state: DisplayState;
  rfb: RfbClient | null;
  spice: SpiceConnection | null;
  presenter: Presenter | null;
  reconnectTimer: Timer | null;
  reconnectDelay: number;
  /** Starts the display again; the reconnect timer calls it. */
  restart: () => void;
};

/** How a client is loaded and opened: `open` gets the relay URL once the bundle is ready. */
type ClientSpec = {
  readonly protocol: Protocol;
  readonly label: string;
  readonly load: () => Promise<void>;
  readonly open: (url: string) => void;
};

const patch = (display: Display, change: Partial<DisplayState>): void => {
  display.state = { ...display.state, ...change };
  display.publish(display.state);
};

const showBadge = (display: Display, kind: BadgeKind, protocol: Protocol | null = null, renderer: Renderer = "canvas"): void => {
  if (display.video.painting()) {
    patch(display, { badge: VIDEO_BADGE });
    return;
  }
  patch(display, { badge: badgeLabel(kind, protocol, renderer), protocol });
};

const stopPresenter = (display: Display): void => {
  display.presenter?.stop();
  display.presenter = null;
  patch(display, { renderer: null });
};

const beginPresenter = (display: Display, protocol: Protocol): void => {
  if (display.surface === null) {
    return;
  }
  display.presenter?.stop();
  display.presenter = startPresenter(display.surface, (mode) => {
    patch(display, { renderer: mode });
    showBadge(display, "connected", protocol, mode);
  });
};

const removeCanvases = (surface: HTMLElement): void => {
  for (const child of surface.children) {
    if (child instanceof HTMLCanvasElement) {
      child.remove();
    }
  }
};

/** Closes a client after the current call stack; one that throws while closing is logged, not fatal. */
const closeClient = (display: Display, label: string, close: () => void): void => {
  Promise.resolve()
    .then(close)
    .catch((closeError: unknown) => {
      display.host.log(`${label} close failed:`, closeError);
    });
};

const stopDisplay = (display: Display): void => {
  display.video.stop();
  stopPresenter(display);
  const { rfb, spice } = display;
  display.rfb = null;
  display.spice = null;
  if (rfb !== null) {
    closeClient(display, "VNC", () => {
      rfb.disconnect();
    });
  }
  if (spice !== null) {
    closeClient(display, "SPICE", () => {
      spice.stop();
    });
  }
  if (display.surface !== null) {
    removeCanvases(display.surface);
  }
  patch(display, { visible: false, loading: false, connected: false, renderer: null, hint: NO_HINT });
  showBadge(display, "disconnected");
};

const scheduleReconnect = (display: Display): void => {
  if (display.reconnectTimer !== null) {
    return;
  }
  display.reconnectTimer = setTimeout(() => {
    display.reconnectTimer = null;
    const index = display.host.selected();
    const vm = index === null ? undefined : display.host.vmAt(index);
    if (vm?.status === "running" && embeddedDisplayCapable(vm) && display.rfb === null && display.spice === null) {
      display.reconnectDelay = nextDelay(display.reconnectDelay, DISPLAY_RECONNECT_MAX_MS);
      display.restart();
    }
  }, display.reconnectDelay);
};

/**
 * Loads the client bundle on first use, then opens the relay. A bundle that fails to load leaves the
 * display visible with a Retry instead of a dead pane.
 */
const connectClient = (display: Display, index: number, spec: ClientSpec): void => {
  const { host } = display;
  patch(display, { hint: { kind: "loading", client: spec.label } });
  const ready = (): void => {
    // The selection may have moved while the bundle downloaded; connecting now would bind a stale VM.
    if (host.selected() !== index) {
      return;
    }
    patch(display, { hint: NO_HINT });
    spec.open(relayUrl(location, spec.protocol, index));
  };
  const failedToLoad = (): void => {
    if (host.selected() !== index) {
      return;
    }
    patch(display, { loading: false, hint: { kind: "failed", client: spec.label } });
    showBadge(display, "disconnected");
  };
  spec
    .load()
    .then(ready, failedToLoad)
    .catch((connectError: unknown) => {
      if (host.selected() === index) {
        host.log(`${spec.label} connect failed:`, connectError);
        stopDisplay(display);
      }
    });
};

const markConnected = (display: Display, protocol: Protocol): void => {
  patch(display, { loading: false, connected: true });
  showBadge(display, "connected", protocol);
  beginPresenter(display, protocol);
};

const clearReconnect = (display: Display): void => {
  if (display.reconnectTimer !== null) {
    clearTimeout(display.reconnectTimer);
    display.reconnectTimer = null;
  }
};

const vncClass = (): RfbConstructor | undefined => globalThis.noVNC?.default ?? globalThis.noVNC?.RFB;

const openVnc = (display: Display, target: HTMLElement, url: string): void => {
  const Client = vncClass();
  if (Client === undefined) {
    throw new Error("noVNC bundle has no RFB class");
  }
  const client = new Client(target, url, {});
  display.rfb = client;
  client.addEventListener("connect", () => {
    display.reconnectDelay = RECONNECT_BASE_MS;
    clearReconnect(display);
    markConnected(display, "vnc");
  });
  client.addEventListener("disconnect", () => {
    stopDisplay(display);
    scheduleReconnect(display);
  });
  client.addEventListener("credentialsrequired", () => {
    client.sendCredentials({ password: "" });
  });
  client.scaleViewport = true;
  client.resizeSession = true;
};

const openSpice = (display: Display, target: HTMLElement, url: string): void => {
  const bundle = globalThis.SpiceHtml5;
  if (bundle === undefined) {
    throw new Error("SPICE bundle did not register");
  }
  display.spice = new bundle.SpiceMainConn({
    uri: url,
    password: "",
    screen_id: target.id,
    onerror: (error) => {
      display.host.log("SPICE error:", error);
      stopDisplay(display);
    },
    onsuccess: () => {
      markConnected(display, "spice");
    },
  });
};

const clientSpec = (display: Display, target: HTMLElement, protocol: Protocol): ClientSpec => {
  if (protocol === "vnc") {
    return {
      protocol,
      label: "VNC",
      load: () => ensureAsset("/novnc.js", () => vncClass() !== undefined),
      open: (url) => {
        openVnc(display, target, url);
      },
    };
  }
  return {
    protocol,
    label: "SPICE",
    load: () => ensureAsset("/spice.js", () => globalThis.SpiceHtml5 !== undefined),
    open: (url) => {
      openSpice(display, target, url);
    },
  };
};

const startClient = (display: Display, index: number, target: HTMLElement, protocol: Protocol): void => {
  stopPresenter(display);
  removeCanvases(target);
  showBadge(display, "connecting", protocol);
  connectClient(display, index, clientSpec(display, target, protocol));
};

const startDisplay = (display: Display): void => {
  if (display.rfb !== null || display.spice !== null) {
    return;
  }
  const index = display.host.selected();
  const vm: Vm | undefined = index === null ? undefined : display.host.vmAt(index);
  const { surface } = display;
  if (index === null || vm?.status !== "running" || surface === null) {
    return;
  }
  patch(display, { visible: true, loading: true, connected: false, hint: NO_HINT });
  display.video.start(index);
  if (vm.display === SPICE_DISPLAY) {
    startClient(display, index, surface, "spice");
  } else if (vm.display === VNC_DISPLAY) {
    startClient(display, index, surface, "vnc");
  } else {
    // GTK, SDL and None have no remote framebuffer.
    const label = DISPLAY_LABELS[vm.display] ?? NATIVE_LABEL_UNKNOWN;
    patch(display, { loading: false, connected: false, renderer: "native", hint: { kind: "native", label } });
    showBadge(display, "native");
  }
};

const reconnectDisplay = (display: Display): void => {
  const index = display.host.selected();
  if (index !== null && display.host.vmAt(index) !== undefined) {
    stopDisplay(display);
    startDisplay(display);
  }
};

export const createDisplayController = (host: DisplayHost, publish: (state: DisplayState) => void): DisplayController => {
  const display: Display = {
    host,
    publish,
    video: createVideoStream(
      host,
      () => display.surface,
      (painting) => {
        patch(display, { video: painting });
        if (painting) {
          showBadge(display, "connected", "vnc");
        }
      },
    ),
    surface: null,
    state: IDLE_DISPLAY,
    rfb: null,
    spice: null,
    presenter: null,
    reconnectTimer: null,
    reconnectDelay: RECONNECT_BASE_MS,
    restart: () => {
      startDisplay(display);
    },
  };
  return {
    attach: (element) => {
      display.surface = element;
    },
    start: () => {
      startDisplay(display);
    },
    stop: () => {
      stopDisplay(display);
    },
    reconnect: () => {
      reconnectDisplay(display);
    },
    hasClient: () => display.rfb !== null || display.spice !== null,
  };
};
