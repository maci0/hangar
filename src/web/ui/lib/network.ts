/** Accent for a virtual network type or NIC mode; maps to the `--network-*` tokens. */
export type NetKind = "nat" | "bridged" | "host_only" | "dim" | "accent";

/** Full class names per kind (Tailwind only emits classes it can read literally). */
export const NET_DOT: Record<NetKind, string> = {
  nat: "bg-net-nat",
  bridged: "bg-net-bridged",
  host_only: "bg-net-host-only",
  dim: "bg-fg-dim",
  accent: "bg-accent",
};

export const NET_BORDER: Record<NetKind, string> = {
  nat: "border-net-nat",
  bridged: "border-net-bridged",
  host_only: "border-net-host-only",
  dim: "border-fg-dim",
  accent: "border-accent",
};

export const NET_STROKE: Record<NetKind, string> = {
  nat: "stroke-net-nat",
  bridged: "stroke-net-bridged",
  host_only: "stroke-net-host-only",
  dim: "stroke-fg-dim",
  accent: "stroke-accent",
};

export const NET_FILL: Record<NetKind, string> = {
  nat: "fill-net-nat",
  bridged: "fill-net-bridged",
  host_only: "fill-net-host-only",
  dim: "fill-fg-dim",
  accent: "fill-accent",
};

/** The accent for a daemon network `type` string; unknown types read as dim. */
export const netKindOf = (type: string): NetKind => {
  switch (type.toLowerCase()) {
    case "nat": {
      return "nat";
    }
    case "bridged": {
      return "bridged";
    }
    case "host_only":
    case "host-only": {
      return "host_only";
    }
    default: {
      return "dim";
    }
  }
};

/** Badge text for a network `type`. */
export const netTypeLabel = (type: string): string => {
  const kind = netKindOf(type);
  if (kind === "nat") {
    return "NAT";
  }
  if (kind === "bridged") {
    return "Bridged";
  }
  if (kind === "host_only") {
    return "Host-Only";
  }
  return type === "" ? "?" : type;
};
