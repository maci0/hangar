import { describe, expect, test } from "bun:test";
import { actionReason } from "@/lib/actions";
import { sampleVm } from "@/lib/vm-fixture";
import type { Vm } from "@/lib/vm";

const stoppedVm: Vm = sampleVm();
const running: Vm = sampleVm({ status: "running" });

describe("actionReason", () => {
  test("asks for a selection when no VM is selected", () => {
    expect(actionReason("rename", null, [])).toBe("Select a VM first");
    expect(actionReason("shutdown", null, [])).toBe("Select a VM first");
  });

  test("batch actions do not need a selection", () => {
    expect(actionReason("batch-start", null, [stoppedVm])).toBeNull();
    expect(actionReason("batch-start", null, [running])).toBe("No stopped VMs");
    expect(actionReason("batch-stop", null, [stoppedVm])).toBe("No running VMs");
    expect(actionReason("batch-stop", null, [running])).toBeNull();
  });

  test("guest controls need a running VM", () => {
    expect(actionReason("pause", stoppedVm, [stoppedVm])).toBe("Requires a running VM");
    expect(actionReason("pause", running, [running])).toBeNull();
    expect(actionReason("power-on", running, [running])).toBe("VM is already running");
    expect(actionReason("resume", running, [running])).toBe("Only paused or suspended VMs can resume");
  });

  test("the console needs an embedded display and serial needs a port", () => {
    expect(actionReason("display", sampleVm({ status: "running", embed_display: "false" }), [running])).toBe("Requires a running VM with embedded VNC or SPICE display");
    expect(actionReason("display", sampleVm({ status: "running", embed_display: "true", display: 3 }), [running])).toBeNull();
    expect(actionReason("serial", sampleVm({ status: "running", hasSerial: "true" }), [running])).toBeNull();
    expect(actionReason("serial", running, [running])).toBe("Requires a running VM with serial enabled");
  });
});
