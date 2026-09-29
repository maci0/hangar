import { describe, expect, test } from "bun:test";
import { embeddedDisplayCapable, networkLabel, videoSummary, vmWarnings } from "@/lib/vm";
import { sampleVm } from "@/lib/vm-fixture";

describe("embeddedDisplayCapable", () => {
  test("needs the embed flag and a SPICE or VNC display", () => {
    expect(embeddedDisplayCapable(sampleVm({ display: 3 }))).toBe(true);
    expect(embeddedDisplayCapable(sampleVm({ display: 2 }))).toBe(true);
    expect(embeddedDisplayCapable(sampleVm({ display: 0 }))).toBe(false);
    expect(embeddedDisplayCapable(sampleVm({ display: 3, embed_display: "false" }))).toBe(false);
  });
});

describe("vmWarnings", () => {
  test("is empty for a working setup", () => {
    expect(vmWarnings(sampleVm())).toEqual([]);
  });

  test("reports an embedded display the browser cannot show", () => {
    expect(vmWarnings(sampleVm({ display: 0 }))).toEqual([
      "Embedded display is enabled, but browser console requires VNC or SPICE.",
    ]);
  });

  test("reports each network that needs host setup", () => {
    expect(vmWarnings(sampleVm({ net: "none" }))).toEqual(["Network adapter is disconnected."]);
    expect(vmWarnings(sampleVm({ net: "gvproxy" }))[0]).toContain("gvproxy daemon");
    expect(vmWarnings(sampleVm({ net: "bridge" }))[0]).toContain("host bridge");
  });
});

describe("networkLabel", () => {
  test("names the modes and defaults an empty one to NAT", () => {
    expect(networkLabel(sampleVm({ net: "user" }))).toBe("NAT (user mode)");
    expect(networkLabel(sampleVm({ net: "" }))).toBe("NAT (user mode)");
    expect(networkLabel(sampleVm({ net: "none" }))).toBe("Disconnected");
    expect(networkLabel(sampleVm({ net: "tap0" }))).toBe("tap0");
  });
});

describe("videoSummary", () => {
  test("drops the virgl suffix while 3D is off", () => {
    expect(videoSummary(sampleVm({ gpu_device: 0, enable_3d: "false" }))).toBe("Embedded VNC · Virtio-GPU · 2D");
  });

  test("keeps it with 3D on, and calls a non-embedded display native", () => {
    expect(videoSummary(sampleVm({ gpu_device: 0, enable_3d: "true", embed_display: "false", display: 0 }))).toBe(
      "Native GTK · Virtio-GPU (virgl 3D) · 3D accelerated",
    );
  });
});
