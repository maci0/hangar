/** Pure logic of the console tab: relay URLs, backoff, badge text, the empty-state notice, the serial buffer and the resize handle. */
import { DISPLAY_LABELS, embeddedDisplayCapable, type Vm } from "@/lib/vm";

export type RelayKind = "vnc" | "spice" | "serial" | "video";

/** The part of `location` the relay URL depends on. */
export type PageLocation = { readonly protocol: string; readonly host: string };

/** WebSocket URL of a console relay; `wss` when the page is served over https. */
export const relayUrl = (loc: PageLocation, kind: RelayKind, index: number): string =>
  `${loc.protocol === "https:" ? "wss:" : "ws:"}//${loc.host}/ws/${kind}/${index}`;

export const RECONNECT_BASE_MS = 1000;
export const DISPLAY_RECONNECT_MAX_MS = 15_000;
export const SERIAL_RECONNECT_MAX_MS = 30_000;
const BACKOFF_FACTOR = 2;

/** The delay after `current`: doubled, never above `max`. */
export const nextDelay = (current: number, max: number): number => Math.min(current * BACKOFF_FACTOR, max);

export type Protocol = "vnc" | "spice";
export type BadgeKind = "connecting" | "connected" | "native" | "disconnected";
/** What paints the display: a GPU presenter or the client's own canvas. */
export type Renderer = "webgpu" | "webgl2" | "webgl" | "canvas";

export const VIDEO_BADGE = "H264 · WEBCODECS";

/** Text of the badge in a corner of the display. */
export const badgeLabel = (kind: BadgeKind, protocol: Protocol | null, renderer: Renderer): string => {
  if (kind === "connecting") {
    return "Connecting…";
  }
  if (kind === "native") {
    return "Native Display";
  }
  if (kind === "connected") {
    return `${(protocol ?? "display").toUpperCase()} · ${renderer.toUpperCase()}`;
  }
  return "Disconnected";
};

/** Renderers that draw through a presenter canvas above the client's. */
export const isGpuRenderer = (renderer: Renderer | "native" | null): boolean =>
  renderer === "webgpu" || renderer === "webgl2" || renderer === "webgl";

export const SERIAL_BUFFER_MAX = 256 * 1024;

/** The export buffer after `chunk`: the newest `SERIAL_BUFFER_MAX` characters. */
export const appendSerial = (buffer: string, chunk: string): string => {
  const next = buffer + chunk;
  return next.length > SERIAL_BUFFER_MAX ? next.slice(next.length - SERIAL_BUFFER_MAX) : next;
};

/** File name of an exported serial log, e.g. `hangar-serial-2026-09-29T12-00-00-000Z.txt`. */
export const serialExportName = (at: Date): string => `hangar-serial-${at.toISOString().replaceAll(/[:.]/gv, "-")}.txt`;

export const SERIAL_MIN_HEIGHT = 60;
export const SERIAL_MAX_HEIGHT = 600;
export const SERIAL_DEFAULT_HEIGHT = 170;
export const SERIAL_STEP = 16;
export const SERIAL_STEP_LARGE = 48;

export const clampSerialHeight = (height: number): number =>
  Math.max(SERIAL_MIN_HEIGHT, Math.min(SERIAL_MAX_HEIGHT, height));

/**
 * The height a key on the resize handle asks for, or null for any other key. Up shrinks and down
 * grows (the handle is the edge under the terminal); Home and End jump to the limits.
 */
export const serialHeightForKey = (key: string, shift: boolean, height: number): number | null => {
  const step = shift ? SERIAL_STEP_LARGE : SERIAL_STEP;
  if (key === "ArrowUp") {
    return clampSerialHeight(height - step);
  }
  if (key === "ArrowDown") {
    return clampSerialHeight(height + step);
  }
  if (key === "Home") {
    return SERIAL_MAX_HEIGHT;
  }
  return key === "End" ? SERIAL_MIN_HEIGHT : null;
};

/** The message that replaces the console when there is nothing to show. */
export type ConsoleNotice = { readonly title: string; readonly detail: string };

/** Why the console tab is empty for this VM, or null when its display should be showing. */
export const consoleNotice = (vm: Vm | null): ConsoleNotice | null => {
  if (vm === null) {
    return {
      title: "No VM selected.",
      detail: "Select a running VM with embedded VNC or SPICE display to open the browser console.",
    };
  }
  if (!embeddedDisplayCapable(vm)) {
    return {
      title: "No embedded browser console for this display.",
      detail: `Switch Display to VNC or SPICE and enable Embed Display in Settings, or use the native ${DISPLAY_LABELS[vm.display] ?? "Display"} QEMU window.`,
    };
  }
  if (vm.status !== "running") {
    return { title: `${vm.name} is powered off.`, detail: "Power on the VM to open its console here." };
  }
  return null;
};
