/** Decoders for the small JSON documents the app reads besides the VM list. A field of the wrong type reads as absent. */

export type Capabilities = {
  readonly version: string;
  readonly maxVms: number;
  readonly maxNics: number;
  readonly maxExtraDisks: number;
};

/** `GET /api/capabilities`. Absent numbers are 0 and an absent version is empty. */
export const parseCapabilities = (body: unknown): Capabilities => {
  const doc = typeof body === "object" && body !== null ? body : {};
  return {
    version: "version" in doc && typeof doc.version === "string" ? doc.version : "",
    maxVms: "max_vms" in doc && typeof doc.max_vms === "number" ? doc.max_vms : 0,
    maxNics: "max_nics" in doc && typeof doc.max_nics === "number" ? doc.max_nics : 0,
    maxExtraDisks: "max_extra_disks" in doc && typeof doc.max_extra_disks === "number" ? doc.max_extra_disks : 0,
  };
};

/** `GET /api/host`: physical cores and memory (MiB); 0 while the daemon does not know. */
export const parseHost = (body: unknown): { readonly cpuCores: number; readonly ramMib: number } => {
  const doc = typeof body === "object" && body !== null ? body : {};
  return {
    cpuCores: "cpu_cores" in doc && typeof doc.cpu_cores === "number" ? doc.cpu_cores : 0,
    ramMib: "ram_mb" in doc && typeof doc.ram_mb === "number" ? doc.ram_mb : 0,
  };
};

/** `GET /api/vms/<n>/guestinfo`: the guest's addresses as `a,b`, empty when the agent is not answering. */
export const parseGuestIps = (body: unknown): string =>
  typeof body === "object" && body !== null && "ips" in body && typeof body.ips === "string" ? body.ips : "";

/** `GET /api/vms/<n>/diskinfo`: null when the daemon reports an error or leaves out a size. */
export const parseDiskInfo = (body: unknown): { readonly actualBytes: number; readonly virtualBytes: number } | null => {
  if (typeof body !== "object" || body === null || "error" in body) {
    return null;
  }
  return "actual_bytes" in body && typeof body.actual_bytes === "number" && "virtual_bytes" in body && typeof body.virtual_bytes === "number"
    ? { actualBytes: body.actual_bytes, virtualBytes: body.virtual_bytes }
    : null;
};

/** The elements of a JSON array (any array-like body); null for anything else. */
export const listOf = (body: unknown): ReadonlyArray<unknown> | null =>
  typeof body === "object" && body !== null && "length" in body && typeof body.length === "number" ? Object.values(body) : null;
