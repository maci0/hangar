import { describe, expect, test } from "bun:test";
import { prefsValues } from "@/lib/prefs";

describe("prefsValues", () => {
  test("a fresh daemon has no stored config: defaults and the theme in effect", () => {
    expect(prefsValues({}, "light")).toEqual({
      theme: "light",
      defaultVmDir: "",
      defaultMemoryMb: "2048",
      defaultCpuCores: "2",
      autoprotectEnabled: "0",
      autoprotectIntervalMin: "60",
      autoprotectMax: "10",
    });
  });

  test("stored values win and booleans become 1 or 0", () => {
    const values = prefsValues(
      { theme: "dark", prefs: { default_vm_dir: "/vms", default_memory_mb: 3072, default_cpu_cores: 3, autoprotect_enabled_default: true } },
      "light",
    );
    expect(values.theme).toBe("dark");
    expect(values.defaultVmDir).toBe("/vms");
    expect(values.defaultMemoryMb).toBe("3072");
    expect(values.autoprotectEnabled).toBe("1");
  });

  test("a body that is not an object reads as empty", () => {
    expect(prefsValues(null, "dark").defaultMemoryMb).toBe("2048");
    expect(prefsValues([1], "dark").theme).toBe("dark");
  });
});
