import type { TopologyLayout, TopologyNode, TopologyTarget } from "@/components/dialogs/topology";
import { netKindOf, type NetKind } from "@/lib/network";
import type { Vm } from "@/lib/vm";
import type { Vnet } from "@/lib/vnet";

/** The part of an elkjs input graph the topology builds. */
export type ElkGraph = {
  readonly id: string;
  readonly layoutOptions: Readonly<Record<string, string>>;
  readonly children: ReadonlyArray<{ readonly id: string; readonly width: number; readonly height: number; readonly labels: ReadonlyArray<{ readonly text: string }> }>;
  readonly edges: ReadonlyArray<{ readonly id: string; readonly sources: ReadonlyArray<string>; readonly targets: ReadonlyArray<string> }>;
};

type Point = { readonly x: number; readonly y: number };

/** The part of elkjs's answer the dialog draws. */
export type ElkResult = {
  readonly width?: number;
  readonly height?: number;
  readonly children?: ReadonlyArray<{ readonly id: string; readonly x: number; readonly y: number; readonly width: number; readonly height: number }>;
  readonly edges?: ReadonlyArray<{
    readonly sections?: ReadonlyArray<{ readonly startPoint: Point; readonly endPoint: Point; readonly bendPoints?: ReadonlyArray<Point> }>;
  }>;
};

export type ElkEngine = { readonly layout: (graph: ElkGraph) => Promise<ElkResult> };

export type NodeMeta = {
  readonly kind: TopologyNode["kind"];
  readonly label: string;
  readonly target: TopologyTarget | null;
  readonly accent: NetKind | null;
  readonly state: string;
};

export type TopologyGraph = { readonly graph: ElkGraph; readonly meta: ReadonlyMap<string, NodeMeta> };

/** The daemon allows NIC 1 plus this many more (`MAX_NICS` is 8). */
const NIC_SLOTS = 8;
const NODE_HEIGHT = 38;
const NODE_MIN_WIDTH = 96;
const NODE_CHAR_WIDTH = 7.2;
const NODE_PADDING = 26;
const DEFAULT_WIDTH = 800;
const DEFAULT_HEIGHT = 400;
const HOST_ID = "host";

const LAYOUT_OPTIONS = {
  "elk.algorithm": "layered",
  "elk.direction": "RIGHT",
  "elk.spacing.nodeNode": "22",
  "elk.layered.spacing.nodeNodeBetweenLayers": "80",
} as const;

const MODE_LABELS: Readonly<Record<string, string>> = { user: "NAT (user)", gvproxy: "gvproxy", bridge: "Bridged", none: "Isolated" };

export const modeLabel = (mode: string): string => MODE_LABELS[mode] ?? mode;

export const modeKind = (mode: string): NetKind => {
  if (mode === "bridge") {
    return "bridged";
  }
  if (mode === "user" || mode === "gvproxy") {
    return "nat";
  }
  return mode === "none" ? "dim" : "accent";
};

/** NIC modes of a VM: NIC 1 (`net`, default `user`) then the configured extra NICs that are not `none`. */
export const vmModes = (vm: Vm): Array<string> => {
  const modes = [vm.net === "" ? "user" : vm.net];
  for (let slot = 2; slot <= NIC_SLOTS; slot += 1) {
    const mode = vm[`nic${slot}_mode`];
    if (mode !== undefined && mode !== "" && mode !== "none") {
      modes.push(mode);
    }
  }
  return modes;
};

/** Virtual networks a VM is bound to: NIC 1's `vnet` and each extra NIC's. */
const boundNetworks = (vm: Vm): Array<string> => {
  const names = [vm.vnet];
  for (let slot = 2; slot <= NIC_SLOTS; slot += 1) {
    names.push(vm[`nic${slot}_vnet`] ?? "");
  }
  return names.filter((name) => name !== "");
};

/** Builds the elk input graph (VMs, virtual networks, NIC modes, the host uplink) and what each node means. */
export const buildTopologyGraph = (vms: ReadonlyArray<Vm>, nets: ReadonlyArray<Vnet>): TopologyGraph => {
  const children: Array<ElkGraph["children"][number]> = [];
  const edges: Array<ElkGraph["edges"][number]> = [];
  const meta = new Map<string, NodeMeta>();
  const edgeKeys = new Set<string>();
  const modesUsed = new Set<string>();
  let anyUplink = false;
  const addNode = (id: string, label: string, node: Omit<NodeMeta, "label">): void => {
    if (!meta.has(id)) {
      const width = Math.max(NODE_MIN_WIDTH, Math.round(label.length * NODE_CHAR_WIDTH) + NODE_PADDING);
      children.push({ id, width, height: NODE_HEIGHT, labels: [{ text: label }] });
      meta.set(id, { ...node, label });
    }
  };
  const addEdge = (from: string, to: string): void => {
    if (!edgeKeys.has(`${from}>${to}`)) {
      edgeKeys.add(`${from}>${to}`);
      edges.push({ id: `e${edges.length}`, sources: [from], targets: [to] });
    }
  };
  const netKind = (name: string): NetKind => {
    const net = nets.find((candidate) => candidate.name === name);
    return net === undefined ? "accent" : netKindOf(net.type);
  };
  for (const vm of vms) {
    addNode(`vm:${vm.name}`, vm.name, { kind: "vm", target: { kind: "vm", name: vm.name }, accent: null, state: vm.status });
    for (const name of boundNetworks(vm)) {
      addNode(`net:${name}`, name, { kind: "vnet", target: { kind: "network", name }, accent: netKind(name), state: "" });
      addEdge(`vm:${vm.name}`, `net:${name}`);
      addEdge(`net:${name}`, HOST_ID);
      anyUplink = true;
    }
    for (const mode of new Set(vmModes(vm))) {
      addNode(`mode:${mode}`, modeLabel(mode), { kind: "net", target: null, accent: modeKind(mode), state: "" });
      modesUsed.add(mode);
      addEdge(`vm:${vm.name}`, `mode:${mode}`);
    }
  }
  for (const net of nets) {
    addNode(`net:${net.name}`, `${net.name} · ${net.type}`, {
      kind: "vnet",
      target: { kind: "network", name: net.name },
      accent: netKindOf(net.type),
      state: "",
    });
    addEdge(`net:${net.name}`, HOST_ID);
    anyUplink = true;
  }
  for (const mode of modesUsed) {
    if (mode !== "none") {
      addEdge(`mode:${mode}`, HOST_ID);
      anyUplink = true;
    }
  }
  if (anyUplink) {
    addNode(HOST_ID, "Host / Physical", { kind: "host", target: null, accent: null, state: "" });
  }
  return { graph: { id: "root", layoutOptions: LAYOUT_OPTIONS, children, edges }, meta };
};

/** Turns elk's answer into what the dialog draws: SVG path data per edge segment and positioned nodes. */
export const topologyLayout = (placed: ElkResult, meta: ReadonlyMap<string, NodeMeta>): TopologyLayout => {
  const edges = (placed.edges ?? []).flatMap((edge) =>
    (edge.sections ?? []).map((section) =>
      [section.startPoint, ...(section.bendPoints ?? []), section.endPoint]
        .map((point, index) => `${index === 0 ? "M" : "L"}${Math.round(point.x)} ${Math.round(point.y)}`)
        .join(" "),
    ),
  );
  const nodes = (placed.children ?? []).map((node): TopologyNode => {
    const known = meta.get(node.id);
    return {
      id: node.id,
      x: node.x,
      y: node.y,
      width: node.width,
      height: node.height,
      label: known?.label ?? node.id,
      kind: known?.kind ?? "net",
      state: known?.state ?? "",
      accent: known?.accent ?? null,
      target: known?.target ?? null,
    };
  });
  return { width: Math.ceil(placed.width ?? DEFAULT_WIDTH), height: Math.ceil(placed.height ?? DEFAULT_HEIGHT), edges, nodes };
};
