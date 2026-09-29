/**
 * The serial console: an xterm.js terminal mounted into the Preact-owned container, fed by the
 * `/ws/serial/<n>` relay. The controller owns the terminal, the socket and the reconnect timer and
 * publishes a `SerialState`; the component draws the panel around it.
 */
import { ensureAsset, ensureStylesheet } from "@/lib/assets";
import { appendSerial, nextDelay, RECONNECT_BASE_MS, relayUrl, SERIAL_RECONNECT_MAX_MS, serialExportName } from "@/lib/console";
import type { Vm } from "@/lib/vm";
import type { FitAddon as XtermFit } from "@xterm/addon-fit";
import type { Terminal as Xterm } from "@xterm/xterm";

/** What the serial console asks of `app.js`. */
export type SerialHost = {
  /** Index of the selected VM in the list, or null. */
  readonly selected: () => number | null;
  readonly vmAt: (index: number) => Vm | undefined;
  readonly log: (message: string, detail: unknown) => void;
};

export type SerialState = {
  /** The panel is shown (a terminal is loading, connecting or connected). */
  readonly visible: boolean;
  readonly connected: boolean;
  /** The line under the panel head: the terminal bundle is loading, or failed and offers Retry. */
  readonly status: "none" | "loading" | "failed";
};

export const IDLE_SERIAL: SerialState = { visible: false, connected: false, status: "none" };

export type SerialController = {
  /** Gives the controller the element the terminal opens in; null when it goes away. */
  readonly attach: (element: HTMLElement | null) => void;
  /** Connects the VM at `index` unless the user disconnected it by hand. */
  readonly start: (index: number) => void;
  /** Closes the socket and hides the panel; `clear` also empties the terminal and the export buffer. */
  readonly stop: (clear: boolean) => void;
  /** Connects the selected VM again (the Retry after the terminal failed to load). */
  readonly reconnect: () => void;
  /** Disconnects and stays disconnected until the page reloads. */
  readonly disconnect: () => void;
  readonly clear: () => void;
  /** Downloads the last output as a text file. */
  readonly exportLog: () => void;
  /** Refits the terminal to its container. */
  readonly fit: () => void;
};

const TERMINAL_FONT_SIZE = 12;
const TERMINAL_SCROLLBACK = 5000;
const REVOKE_DELAY_MS = 100;

type Timer = ReturnType<typeof setTimeout>;

type Serial = {
  readonly host: SerialHost;
  readonly publish: (state: SerialState) => void;
  container: HTMLElement | null;
  state: SerialState;
  terminal: Xterm | null;
  fitAddon: XtermFit | null;
  socket: WebSocket | null;
  socketIndex: number | null;
  /** VM the user disconnected by hand; it stays off until the page reloads. */
  manualOffIndex: number | null;
  reconnectDelay: number;
  reconnectTimer: Timer | null;
  /** Shadow of the output for export; the terminal's own buffer is not readable as text. */
  buffer: string;
  /** Connects a VM again; the reconnect timer calls it. */
  restart: (index: number) => void;
};

const patch = (serial: Serial, change: Partial<SerialState>): void => {
  serial.state = { ...serial.state, ...change };
  serial.publish(serial.state);
};

const cssToken = (name: string): string => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

/** Terminal colors follow the page tokens, so a theme change reaches the terminal too. */
const terminalTheme = () => ({
  background: cssToken("--serial-bg"),
  foreground: cssToken("--serial-text"),
  cursor: cssToken("--serial-fg"),
  cursorAccent: cssToken("--serial-bg"),
  selectionBackground: cssToken("--serial-selection"),
});

const loadTerminalBundles = async (): Promise<void> => {
  await Promise.all([ensureStylesheet("/xterm.css"), ensureAsset("/xterm.js", () => globalThis.Terminal !== undefined)]);
  await Promise.all([
    ensureAsset("/xterm-fit.js", () => globalThis.FitAddon !== undefined),
    ensureAsset("/xterm-webgl.js", () => globalThis.WebglAddon !== undefined),
  ]);
};

const clearReconnect = (serial: Serial): void => {
  if (serial.reconnectTimer !== null) {
    clearTimeout(serial.reconnectTimer);
    serial.reconnectTimer = null;
  }
  serial.reconnectDelay = RECONNECT_BASE_MS;
};

const stopSerial = (serial: Serial, clear: boolean): void => {
  clearReconnect(serial);
  serial.socket?.close();
  serial.socket = null;
  serial.socketIndex = null;
  if (clear) {
    serial.terminal?.reset();
    serial.buffer = "";
  }
  patch(serial, { visible: false, connected: false, status: "none" });
};

/** The WebGL renderer is an upgrade: where the GPU refuses it, xterm keeps its DOM renderer. */
const addWebgl = (serial: Serial, terminal: Xterm): void => {
  const bundle = globalThis.WebglAddon;
  if (bundle === undefined) {
    return;
  }
  Promise.resolve()
    .then(() => {
      terminal.loadAddon(new bundle.WebglAddon());
    })
    .catch((webglError: unknown) => {
      serial.host.log("xterm WebGL unavailable, using the DOM renderer:", webglError);
    });
};

const createTerminal = (serial: Serial, target: HTMLElement): Xterm => {
  const { Terminal, FitAddon } = globalThis;
  if (Terminal === undefined || FitAddon === undefined) {
    throw new Error("xterm did not register");
  }
  const terminal = new Terminal({
    fontSize: TERMINAL_FONT_SIZE,
    fontFamily: cssToken("--font-mono"),
    cursorBlink: true,
    scrollback: TERMINAL_SCROLLBACK,
    convertEol: false,
    theme: terminalTheme(),
  });
  serial.fitAddon = new FitAddon.FitAddon();
  terminal.loadAddon(serial.fitAddon);
  terminal.open(target);
  addWebgl(serial, terminal);
  terminal.onData((data) => {
    if (serial.socket?.readyState === WebSocket.OPEN) {
      serial.socket.send(data);
    }
  });
  new MutationObserver(() => {
    terminal.options.theme = terminalTheme();
  }).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
  serial.fitAddon.fit();
  return terminal;
};

const openTerminal = (serial: Serial): Promise<Xterm | null> => {
  const target = serial.container;
  if (serial.terminal !== null || target === null) {
    return Promise.resolve(serial.terminal);
  }
  patch(serial, { status: "loading" });
  return loadTerminalBundles()
    .then(() => {
      const terminal = createTerminal(serial, target);
      serial.terminal = terminal;
      patch(serial, { status: "none" });
      return terminal;
    })
    .catch((loadError: unknown) => {
      serial.host.log("Serial terminal failed to load:", loadError);
      patch(serial, { status: "failed" });
      return null;
    });
};

const scheduleReconnect = (serial: Serial): void => {
  if (serial.reconnectTimer !== null) {
    return;
  }
  serial.reconnectTimer = setTimeout(() => {
    serial.reconnectTimer = null;
    const index = serial.host.selected();
    const vm = index === null ? undefined : serial.host.vmAt(index);
    if (index === null || vm === undefined) {
      return;
    }
    if (serial.manualOffIndex === index) {
      serial.reconnectDelay = RECONNECT_BASE_MS;
    } else if (vm.status === "running" && vm.hasSerial === "true") {
      serial.restart(index);
      serial.reconnectDelay = nextDelay(serial.reconnectDelay, SERIAL_RECONNECT_MAX_MS);
    } else {
      serial.reconnectDelay = RECONNECT_BASE_MS;
    }
  }, serial.reconnectDelay);
};

const receive = (serial: Serial, terminal: Xterm, payload: ArrayBuffer | string): void => {
  if (typeof payload === "string") {
    terminal.write(payload);
    serial.buffer = appendSerial(serial.buffer, payload);
    return;
  }
  terminal.write(new Uint8Array(payload));
  serial.buffer = appendSerial(serial.buffer, new TextDecoder("utf-8", { fatal: false }).decode(payload));
};

const connectSocket = (serial: Serial, index: number, terminal: Xterm): void => {
  const socket = new WebSocket(relayUrl(location, "serial", index));
  socket.binaryType = "arraybuffer";
  // Assigned before the old socket's close event fires, so that event cannot tear this one down.
  serial.socket = socket;
  const gone = (): void => {
    if (serial.socket !== socket) {
      return;
    }
    serial.socket = null;
    serial.socketIndex = null;
    patch(serial, { visible: false, connected: false });
    if (serial.manualOffIndex !== index) {
      scheduleReconnect(serial);
    }
  };
  socket.addEventListener("message", (event: MessageEvent<ArrayBuffer | string>) => {
    receive(serial, terminal, event.data);
  });
  socket.addEventListener("open", () => {
    serial.reconnectDelay = RECONNECT_BASE_MS;
    patch(serial, { connected: true });
    serial.fitAddon?.fit();
  });
  socket.addEventListener("close", gone);
  socket.addEventListener("error", gone);
};

/** Drops a socket that is not the one wanted, or keeps a live one for the same VM. Returns true to keep it. */
const keepSocket = (serial: Serial, index: number): boolean => {
  const { socket } = serial;
  if (socket === null) {
    return false;
  }
  if (serial.socketIndex === index && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
    return true;
  }
  socket.close();
  serial.socket = null;
  return false;
};

const startSerial = (serial: Serial, index: number): void => {
  if (serial.manualOffIndex === index) {
    return;
  }
  clearReconnect(serial);
  if (keepSocket(serial, index)) {
    return;
  }
  const sameVm = serial.socketIndex === index;
  // The terminal is cleared only when the VM changes.
  stopSerial(serial, !sameVm);
  const vm = serial.host.vmAt(index);
  if (vm?.status !== "running" || vm.hasSerial !== "true") {
    return;
  }
  serial.socketIndex = index;
  patch(serial, { visible: true, connected: true });
  // The terminal bundle may still be downloading. The socket opens once it is ready, unless the selection moved on.
  void openTerminal(serial).then((terminal) => {
    if (terminal === null || serial.host.selected() !== index) {
      return;
    }
    if (!sameVm) {
      terminal.reset();
      serial.buffer = "";
    }
    connectSocket(serial, index, terminal);
  });
};

const exportSerial = (serial: Serial): void => {
  if (serial.buffer === "") {
    return;
  }
  const url = URL.createObjectURL(new Blob([serial.buffer], { type: "text/plain" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = serialExportName(new Date());
  link.click();
  setTimeout(() => {
    URL.revokeObjectURL(url);
  }, REVOKE_DELAY_MS);
};

export const createSerialController = (host: SerialHost, publish: (state: SerialState) => void): SerialController => {
  const serial: Serial = {
    host,
    publish,
    container: null,
    state: IDLE_SERIAL,
    terminal: null,
    fitAddon: null,
    socket: null,
    socketIndex: null,
    manualOffIndex: null,
    reconnectDelay: RECONNECT_BASE_MS,
    reconnectTimer: null,
    buffer: "",
    restart: (index) => {
      startSerial(serial, index);
    },
  };
  return {
    attach: (element) => {
      serial.container = element;
    },
    start: (index) => {
      startSerial(serial, index);
    },
    stop: (clear) => {
      stopSerial(serial, clear);
    },
    reconnect: () => {
      const index = host.selected();
      if (index !== null && host.vmAt(index) !== undefined) {
        startSerial(serial, index);
      }
    },
    disconnect: () => {
      serial.manualOffIndex = host.selected();
      clearReconnect(serial);
      stopSerial(serial, true);
    },
    clear: () => {
      serial.terminal?.reset();
      serial.buffer = "";
    },
    exportLog: () => {
      exportSerial(serial);
    },
    fit: () => {
      serial.fitAddon?.fit();
    },
  };
};
