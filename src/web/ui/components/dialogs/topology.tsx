import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogTitle } from "@/components/ui/dialog";
import { cn } from "@/lib/cn";
import { NET_FILL, NET_STROKE, type NetKind } from "@/lib/network";

/** What clicking a node does. */
export type TopologyTarget = { readonly kind: "vm" | "network"; readonly name: string };

export type TopologyNode = {
  readonly id: string;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  readonly label: string;
  /** `vm` and `vnet` can be opened; `net` is a NIC mode; `host` is the uplink. */
  readonly kind: "vm" | "vnet" | "net" | "host";
  /** VM power state (`running`, `paused`, ...); empty for anything else. */
  readonly state: string;
  readonly accent: NetKind | null;
  readonly target: TopologyTarget | null;
};

export type TopologyLayout = {
  readonly width: number;
  readonly height: number;
  /** SVG path data, one per edge segment. */
  readonly edges: ReadonlyArray<string>;
  readonly nodes: ReadonlyArray<TopologyNode>;
};

export type TopologyView =
  | { readonly kind: "loading"; readonly message: string }
  | { readonly kind: "failed"; readonly message: string }
  | { readonly kind: "empty" }
  | { readonly kind: "ready"; readonly layout: TopologyLayout };

export type TopologyState = {
  readonly view: TopologyView;
  /** Called with the target of a clicked node; the caller closes this dialog and navigates. */
  readonly open: (target: TopologyTarget) => void;
  /** Computes the layout again (Refresh, and Retry after a failure). */
  readonly refresh: () => void;
};

const MESSAGE = "p-9 text-center text-field text-fg-dim";

const NODE_RECT: Record<TopologyNode["kind"], string> = {
  vm: "fill-surface stroke-border-hover group-hover:stroke-accent group-hover:stroke-2",
  vnet: "fill-accent-soft stroke-accent group-hover:stroke-2",
  net: "fill-accent-soft stroke-accent-2",
  host: "fill-bg-alt stroke-fg-dim [stroke-dasharray:4_3]",
};

const VM_STATE_STROKE: Record<string, string> = {
  running: "stroke-success",
  paused: "stroke-pause",
};

const rectClass = (node: TopologyNode): string => {
  const accent = node.accent !== null && node.kind !== "vm" ? NET_STROKE[node.accent] : "";
  const state = node.kind === "vm" ? (VM_STATE_STROKE[node.state] ?? "") : "";
  return cn("stroke-1", NODE_RECT[node.kind], accent, state);
};

const TEXT_INSET = 4;

const NodeView = ({ node, open }: { readonly node: TopologyNode; readonly open: TopologyState["open"] }) => {
  const { target } = node;
  const act = () => {
    if (target !== null) {
      open(target);
    }
  };
  const onKeyDown = (event: KeyboardEvent) => {
    if (target !== null && (event.key === "Enter" || event.key === " ")) {
      event.preventDefault();
      act();
    }
  };
  return (
    <g
      class={cn("topo-node group outline-accent focus-visible:outline-2", node.kind, node.state, target !== null && "cursor-pointer")}
      transform={`translate(${Math.round(node.x)},${Math.round(node.y)})`}
      role={target === null ? "img" : "button"}
      tabindex={target === null ? undefined : 0}
      aria-label={node.label}
      onClick={act}
      onKeyDown={onKeyDown}
    >
      <rect width={node.width} height={node.height} rx="3" class={rectClass(node)} />
      {node.accent !== null && <rect width="4" height={node.height} rx="3" class={NET_FILL[node.accent]} />}
      <text
        x={node.width / 2}
        y={node.height / 2 + TEXT_INSET}
        text-anchor="middle"
        class={cn("text-xs", node.kind === "net" || node.kind === "host" ? "fill-fg-muted" : "fill-fg")}
      >
        {node.label}
      </text>
    </g>
  );
};

const Graph = ({ layout, open }: { readonly layout: TopologyLayout; readonly open: TopologyState["open"] }) => (
  <svg
    viewBox={`0 0 ${layout.width} ${layout.height}`}
    class="topo-svg block h-auto w-full p-3"
    preserveAspectRatio="xMidYMid meet"
    role="group"
    aria-label="Network topology diagram"
  >
    {layout.edges.map((path) => (
      <path key={path} d={path} class="topo-edge fill-none stroke-border-hover stroke-1" />
    ))}
    {layout.nodes.map((node) => (
      <NodeView key={node.id} node={node} open={open} />
    ))}
  </svg>
);

const Body = ({ state }: { readonly state: TopologyState }) => {
  const { view } = state;
  switch (view.kind) {
    case "loading": {
      return (
        <div role="status" class={MESSAGE}>
          {view.message}
        </div>
      );
    }
    case "failed": {
      return (
        <div role="alert" class={MESSAGE}>
          {view.message}{" "}
          <Button type="button" data-action="openTopology" onClick={state.refresh}>
            Retry
          </Button>
        </div>
      );
    }
    case "empty": {
      return <div class={MESSAGE}>No VMs or networks to display.</div>;
    }
    case "ready": {
      return <Graph layout={view.layout} open={state.open} />;
    }
    default: {
      return null;
    }
  }
};

export type TopologyDialogProps = {
  readonly state: TopologyState;
  readonly onClose: () => void;
};

/** Network Topology. The app loads the layout engine, computes the layout and pushes the view. */
export const TopologyDialog = ({ state, onClose }: TopologyDialogProps) => (
  <Dialog id="topodlg" titleId="topo-title" class="w-250" onClose={onClose}>
    <DialogTitle id="topo-title">Network Topology</DialogTitle>
    <DialogBody class="grid min-h-0 gap-2">
      <p class="text-xs text-fg-dim">
        Virtual networks, the VMs attached to each (by NIC mode), and the host uplink. Click a VM to open it; click a network to edit it.
      </p>
      <div id="topoWrap" class="topo-wrap max-h-140 min-h-70 overflow-auto rounded-md border border-border-soft bg-bg">
        <Body state={state} />
      </div>
    </DialogBody>
    <DialogFooter>
      <Button type="button" data-action="openTopology" onClick={state.refresh} title="Recompute layout">
        <Icon name="refresh" />
        Refresh
      </Button>
      <DialogClose>Close</DialogClose>
    </DialogFooter>
  </Dialog>
);
