/** One virtual network as the daemon stores it (`GET`/`POST /api/networks`). */
export type Vnet = {
  readonly name: string;
  /** `nat`, `bridged` or `host_only`. */
  readonly type: string;
  readonly subnet: string;
  readonly mask: string;
  readonly dhcp: boolean;
  readonly dhcp_start: string;
  readonly dhcp_end: string;
  readonly host_iface: string;
  readonly gateway: string;
  /** `host:guest` pairs, comma separated. */
  readonly port_forwards: string;
};

/** The fields that can fail validation. */
export type VnetErrors = Partial<Record<"name" | "subnet" | "mask" | "dhcp_start" | "dhcp_end" | "gateway", string>>;

/** Longest name the daemon keeps (its buffer is 16 bytes with a terminator). */
export const VNET_NAME_MAX = 15;
/** The daemon stores at most this many networks. */
export const VNET_MAX = 20;

const OCTET_COUNT = 4;
const OCTET_MAX = 255;
const OCTET_BITS = 8;
const OCTET = /^(?:0|[1-9]\d{0,2})$/u;
const ONES_THEN_ZEROS = /^1+0*$/u;
const CONTROL_CHARS =/\p{Cc}/gu;

const octets = (text: string): ReadonlyArray<number> | null => {
  const parts = text.split(".");
  if (parts.length !== OCTET_COUNT || !parts.every((part) => OCTET.test(part))) {
    return null;
  }
  const values = parts.map(Number);
  return values.every((value) => value <= OCTET_MAX) ? values : null;
};

/** Dotted quad with no leading zeros, as the daemon accepts it. */
export const isIpv4 = (text: string): boolean => octets(text) !== null;

/** A mask is a run of one bits followed by zero bits. */
export const isNetmask = (text: string): boolean => {
  const parts = octets(text);
  if (parts === null) {
    return false;
  }
  const binary = parts.map((part) => part.toString(2).padStart(OCTET_BITS, "0")).join("");
  return ONES_THEN_ZEROS.test(binary);
};

/** Drops control characters; the daemon fields are single-line. */
export const stripControl = (text: string): string => text.replaceAll(CONTROL_CHARS, "");

/** The network as it is sent: text fields trimmed, control characters removed. */
export const cleanVnet = (net: Vnet): Vnet => ({
  ...net,
  name: stripControl(net.name).trim(),
  subnet: net.subnet.trim(),
  mask: net.mask.trim(),
  dhcp_start: net.dhcp_start.trim(),
  dhcp_end: net.dhcp_end.trim(),
  gateway: net.gateway.trim(),
  host_iface: stripControl(net.host_iface).trim(),
  port_forwards: stripControl(net.port_forwards),
});

/** Problems with `net`, keyed by field; empty when it can be saved. Empty optional fields pass. */
export const validateVnet = (net: Vnet): VnetErrors => {
  const clean = cleanVnet(net);
  const errors: { -readonly [K in keyof VnetErrors]: string } = {};
  if (clean.name === "") {
    errors.name = "Network name is required.";
  } else if (clean.name.length > VNET_NAME_MAX) {
    errors.name = `Network name is at most ${VNET_NAME_MAX} characters.`;
  }
  if (clean.subnet !== "" && !isIpv4(clean.subnet)) {
    errors.subnet = "Invalid subnet format.";
  }
  if (clean.mask !== "" && !isNetmask(clean.mask)) {
    errors.mask = "Invalid mask format.";
  }
  if (clean.dhcp_start !== "" && !isIpv4(clean.dhcp_start)) {
    errors.dhcp_start = "Invalid DHCP start IP format.";
  }
  if (clean.dhcp_end !== "" && !isIpv4(clean.dhcp_end)) {
    errors.dhcp_end = "Invalid DHCP end IP format.";
  }
  if (clean.gateway !== "" && !isIpv4(clean.gateway)) {
    errors.gateway = "Invalid gateway IP format.";
  }
  return errors;
};

/** Index of the first network with a problem, or -1. */
export const firstInvalid = (nets: ReadonlyArray<Vnet>): number =>
  nets.findIndex((net) => Object.keys(validateVnet(net)).length > 0);
