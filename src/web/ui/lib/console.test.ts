import { describe, expect, test } from "bun:test";
import {
  appendSerial,
  badgeLabel,
  clampSerialHeight,
  consoleNotice,
  DISPLAY_RECONNECT_MAX_MS,
  isGpuRenderer,
  nextDelay,
  RECONNECT_BASE_MS,
  relayUrl,
  SERIAL_BUFFER_MAX,
  SERIAL_MAX_HEIGHT,
  SERIAL_MIN_HEIGHT,
  SERIAL_RECONNECT_MAX_MS,
  serialExportName,
  serialHeightForKey,
} from "@/lib/console";
import { sampleVm } from "@/lib/vm-fixture";
import type { Vm } from "@/lib/vm";

describe("relayUrl", () => {
  test("uses ws over http and wss over https", () => {
    expect(relayUrl({ protocol: "http:", host: "127.0.0.1:9080" }, "vnc", 2)).toBe("ws://127.0.0.1:9080/ws/vnc/2");
    expect(relayUrl({ protocol: "https:", host: "hangar.example" }, "spice", 0)).toBe("wss://hangar.example/ws/spice/0");
  });

  test("names the relay and the VM index", () => {
    const loc = { protocol: "http:", host: "h" };
    expect(relayUrl(loc, "serial", 11)).toBe("ws://h/ws/serial/11");
    expect(relayUrl(loc, "video", 3)).toBe("ws://h/ws/video/3");
  });
});

describe("nextDelay", () => {
  test("doubles until the cap", () => {
    expect(nextDelay(RECONNECT_BASE_MS, DISPLAY_RECONNECT_MAX_MS)).toBe(2000);
    expect(nextDelay(8000, DISPLAY_RECONNECT_MAX_MS)).toBe(DISPLAY_RECONNECT_MAX_MS);
    expect(nextDelay(DISPLAY_RECONNECT_MAX_MS, DISPLAY_RECONNECT_MAX_MS)).toBe(DISPLAY_RECONNECT_MAX_MS);
    expect(nextDelay(20_000, SERIAL_RECONNECT_MAX_MS)).toBe(SERIAL_RECONNECT_MAX_MS);
  });
});

describe("badgeLabel", () => {
  test("names protocol and renderer once connected", () => {
    expect(badgeLabel("connected", "spice", "webgl2")).toBe("SPICE · WEBGL2");
    expect(badgeLabel("connected", "vnc", "canvas")).toBe("VNC · CANVAS");
    expect(badgeLabel("connected", null, "canvas")).toBe("DISPLAY · CANVAS");
  });

  test("has a fixed text for the other states", () => {
    expect(badgeLabel("connecting", "vnc", "canvas")).toBe("Connecting…");
    expect(badgeLabel("native", null, "canvas")).toBe("Native Display");
    expect(badgeLabel("disconnected", null, "canvas")).toBe("Disconnected");
  });
});

describe("isGpuRenderer", () => {
  test("is true for the presenters and false for the client canvas", () => {
    expect(isGpuRenderer("webgpu")).toBe(true);
    expect(isGpuRenderer("webgl")).toBe(true);
    expect(isGpuRenderer("canvas")).toBe(false);
    expect(isGpuRenderer("native")).toBe(false);
    expect(isGpuRenderer(null)).toBe(false);
  });
});

describe("appendSerial", () => {
  test("appends below the cap", () => {
    expect(appendSerial("ab", "cd")).toBe("abcd");
  });

  test("keeps the newest characters past the cap", () => {
    const full = "a".repeat(SERIAL_BUFFER_MAX);
    const next = appendSerial(full, "xyz");
    expect(next.length).toBe(SERIAL_BUFFER_MAX);
    expect(next.endsWith("axyz")).toBe(true);
  });
});

describe("serialExportName", () => {
  test("has no colons or dots in the timestamp", () => {
    expect(serialExportName(new Date("2026-09-29T12:34:56.789Z"))).toBe("hangar-serial-2026-09-29T12-34-56-789Z.txt");
  });
});

describe("serial resize handle", () => {
  test("clamps to the limits", () => {
    expect(clampSerialHeight(10)).toBe(SERIAL_MIN_HEIGHT);
    expect(clampSerialHeight(900)).toBe(SERIAL_MAX_HEIGHT);
    expect(clampSerialHeight(240)).toBe(240);
  });

  test("arrows move by 16 and by 48 with Shift", () => {
    expect(serialHeightForKey("ArrowDown", false, 200)).toBe(216);
    expect(serialHeightForKey("ArrowUp", false, 200)).toBe(184);
    expect(serialHeightForKey("ArrowDown", true, 200)).toBe(248);
    expect(serialHeightForKey("ArrowUp", true, 200)).toBe(152);
  });

  test("arrows stop at the limits", () => {
    expect(serialHeightForKey("ArrowUp", true, 70)).toBe(SERIAL_MIN_HEIGHT);
    expect(serialHeightForKey("ArrowDown", true, 590)).toBe(SERIAL_MAX_HEIGHT);
  });

  test("Home is the tallest and End the shortest", () => {
    expect(serialHeightForKey("Home", false, 200)).toBe(SERIAL_MAX_HEIGHT);
    expect(serialHeightForKey("End", false, 200)).toBe(SERIAL_MIN_HEIGHT);
  });

  test("ignores other keys", () => {
    expect(serialHeightForKey("Enter", false, 200)).toBeNull();
    expect(serialHeightForKey("a", true, 200)).toBeNull();
  });
});

describe("consoleNotice", () => {
  const running: Vm = sampleVm({ status: "running", embed_display: "true", display: 3 });

  test("asks for a selection when there is none", () => {
    expect(consoleNotice(null)?.title).toBe("No VM selected.");
  });

  test("shows nothing for a running VM with an embedded display", () => {
    expect(consoleNotice(running)).toBeNull();
    expect(consoleNotice({ ...running, display: 2 })).toBeNull();
  });

  test("says a stopped VM is powered off", () => {
    expect(consoleNotice({ ...running, status: "stopped" })).toEqual({
      title: "web-01 is powered off.",
      detail: "Power on the VM to open its console here.",
    });
  });

  test("names the display when it cannot be embedded", () => {
    const notice = consoleNotice({ ...running, embed_display: "false", display: 0 });
    expect(notice?.title).toBe("No embedded browser console for this display.");
    expect(notice?.detail).toContain("native GTK QEMU window");
    expect(consoleNotice({ ...running, display: 1 })?.detail).toContain("native SDL QEMU window");
  });

  test("falls back to a generic label for an unknown display", () => {
    expect(consoleNotice({ ...running, display: 9 })?.detail).toContain("native Display QEMU window");
  });
});
