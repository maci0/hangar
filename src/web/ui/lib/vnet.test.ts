import { describe, expect, test } from "bun:test";
import { parseVnets } from "@/lib/vnet";

const net = { name: "VMnet1", type: "host_only", subnet: "192.168.118.0", mask: "255.255.255.0", dhcp: true, dhcp_start: "a", dhcp_end: "b", host_iface: "", gateway: "", port_forwards: "" };

describe("parseVnets", () => {
  test("reads complete records", () => {
    expect(parseVnets({ networks: [net] })).toEqual([net]);
    expect(parseVnets({ networks: [] })).toEqual([]);
  });

  test("an incomplete record or a wrong body is a failed load, not an empty set", () => {
    expect(parseVnets({ networks: [{ name: "x" }] })).toBeNull();
    expect(parseVnets({})).toBeNull();
    expect(parseVnets(undefined)).toBeNull();
  });
});
