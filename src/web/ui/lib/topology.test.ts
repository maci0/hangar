import { describe, expect, test } from "bun:test";
import { buildTopologyGraph, modeKind, modeLabel, topologyLayout, vmModes } from "@/lib/topology";
import { sampleVm } from "@/lib/vm-fixture";
import type { Vnet } from "@/lib/vnet";

const nat: Vnet = { name: "VMnet8", type: "nat", subnet: "", mask: "", dhcp: true, dhcp_start: "", dhcp_end: "", host_iface: "", gateway: "", port_forwards: "" };

describe("topology graph", () => {
  test("a VM links to its NIC mode, a bound network and the host", () => {
    const vm = sampleVm({ name: "web", net: "user", vnet: "VMnet8" });
    const { graph, meta } = buildTopologyGraph([vm], [nat]);
    const ids = graph.children.map((node) => node.id);
    expect(ids).toEqual(["vm:web", "net:VMnet8", "mode:user", "host"]);
    expect(meta.get("net:VMnet8")).toMatchObject({ kind: "vnet", accent: "nat", target: { kind: "network", name: "VMnet8" } });
    const links = graph.edges.map((edge) => `${edge.sources[0]}>${edge.targets[0]}`);
    expect(links).toContain("vm:web>net:VMnet8");
    expect(links).toContain("net:VMnet8>host");
    expect(links).toContain("mode:user>host");
  });

  test("an isolated VM alone has no host uplink", () => {
    const { graph } = buildTopologyGraph([sampleVm({ name: "iso", net: "none" })], []);
    expect(graph.children.map((node) => node.id)).toEqual(["vm:iso", "mode:none"]);
  });

  test("no VMs and no networks is an empty graph", () => {
    expect(buildTopologyGraph([], []).graph.children).toEqual([]);
  });

  test("NIC modes come from the extra NICs too", () => {
    expect(vmModes(sampleVm({ net: "", nic2_mode: "bridge", nic3_mode: "none" }))).toEqual(["user", "bridge"]);
    expect(modeLabel("bridge")).toBe("Bridged");
    expect(modeKind("gvproxy")).toBe("nat");
  });
});

describe("topologyLayout", () => {
  test("turns elk output into path data and positioned nodes", () => {
    const built = buildTopologyGraph([sampleVm({ name: "web" })], []);
    const layout = topologyLayout(
      {
        width: 200.2,
        height: 80,
        children: [{ id: "vm:web", x: 1, y: 2, width: 96, height: 38 }],
        edges: [{ sections: [{ startPoint: { x: 0.4, y: 0.6 }, bendPoints: [{ x: 5, y: 5 }], endPoint: { x: 9, y: 9 } }] }],
      },
      built.meta,
    );
    expect(layout.width).toBe(201);
    expect(layout.edges).toEqual(["M0 1 L5 5 L9 9"]);
    expect(layout.nodes[0]).toMatchObject({ id: "vm:web", label: "web", kind: "vm", target: { kind: "vm", name: "web" } });
  });
});
