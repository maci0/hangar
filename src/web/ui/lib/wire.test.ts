import { describe, expect, test } from "bun:test";
import { listOf, parseCapabilities, parseDiskInfo, parseGuestIps, parseHost } from "@/lib/wire";

describe("wire decoders", () => {
  test("capabilities read the fields that have the right type", () => {
    expect(parseCapabilities({ version: "0.4.0", max_vms: 64, max_nics: 8, max_extra_disks: "4" })).toEqual({
      version: "0.4.0",
      maxVms: 64,
      maxNics: 8,
      maxExtraDisks: 0,
    });
    expect(parseCapabilities(null).maxVms).toBe(0);
  });

  test("host reads cores and memory", () => {
    expect(parseHost({ cpu_cores: 32, ram_mb: 128_462 })).toEqual({ cpuCores: 32, ramMib: 128_462 });
    expect(parseHost([]).cpuCores).toBe(0);
  });

  test("guest ips are empty unless the agent answered with text", () => {
    expect(parseGuestIps({ ips: "10.0.0.2,fe80::1" })).toBe("10.0.0.2,fe80::1");
    expect(parseGuestIps({ ips: 4 })).toBe("");
    expect(parseGuestIps("x")).toBe("");
  });

  test("disk info needs both sizes and no error", () => {
    expect(parseDiskInfo({ actual_bytes: 10, virtual_bytes: 20 })).toEqual({ actualBytes: 10, virtualBytes: 20 });
    expect(parseDiskInfo({ error: "no disk" })).toBeNull();
    expect(parseDiskInfo({ actual_bytes: 10 })).toBeNull();
  });
});

describe("listOf", () => {
  test("reads arrays and rejects other bodies", () => {
    expect(listOf([1, "a"])).toEqual([1, "a"]);
    expect(listOf([])).toEqual([]);
    expect(listOf({ error: "x" })).toBeNull();
    expect(listOf("text")).toBeNull();
    expect(listOf(null)).toBeNull();
  });
});
