/** Config flags reach the UI as these strings (`app.js` coerces the daemon's JSON booleans). */
export type Flag = "true" | "false";

export type VmStatus = "running" | "paused" | "suspended" | "stopped";

/** OS emblem: monogram on a brand color (a CSS color or `var(--accent)`). */
export type OsBrand = { readonly color: string; readonly text: string };

type NicSlots = Readonly<Partial<Record<`nic${number}_${"mode" | "mac" | "vnet"}`, string>>>;
type ExtraDiskSlots = Readonly<Partial<Record<`extra${number}_${"path" | "size" | "format"}`, string | number>>>;

type VmFields = {
  readonly id: string;
  readonly name: string;
  readonly status: VmStatus;
  readonly os: string;
  readonly mem: number;
  readonly cpu: number;
  readonly cpu_sockets: number;
  readonly disk: number;
  readonly disk_format: number;
  readonly disk_cache: number;
  readonly net: string;
  readonly fw: string;
  readonly hasIso: Flag;
  readonly hasDisk: Flag;
  readonly iso_path: string;
  readonly notes: string;
  readonly shared_folder: string;
  readonly usb_device: string;
  readonly usb_policy: number;
  readonly guest_tools: Flag;
  readonly autoprotect: Flag;
  readonly autoprotect_interval: number;
  readonly autoprotect_max: number;
  readonly hasDisk2: Flag;
  readonly disk2_size: number;
  readonly disk2_path: string;
  readonly disk2_format: number;
  readonly hasFloppy: Flag;
  readonly floppy_path: string;
  readonly port_forwards: string;
  readonly tags: string;
  readonly folder: string;
  readonly mac: string;
  readonly vnet: string;
  readonly num_displays: number;
  readonly hasSerial: Flag;
  readonly virtio_rng: Flag;
  readonly guest_agent: Flag;
  readonly watchdog: number;
  readonly tpm: Flag;
  readonly secure_boot: Flag;
  readonly hyperv_enlightenments: Flag;
  readonly hugepages: Flag;
  readonly io_threads: number;
  readonly disk_bps_throttle: number;
  readonly disk_iops_throttle: number;
  readonly ballooning: Flag;
  readonly host_autostart: Flag;
  readonly enable_3d: Flag;
  readonly gpu_device: number;
  readonly display: number;
  readonly display_resolution: number;
  readonly guest_os: number;
  readonly audio: number;
  readonly boot_order: number;
  readonly rtc: number;
  readonly cpu_model: string;
  readonly accel: string;
  readonly embed_display: Flag;
  readonly vnc_port: number;
  readonly spice_port: number;
  readonly favorite: Flag;
  readonly video_stream: Flag;
  readonly video_bitrate_kbps: number;
  /** Not part of the list JSON: the settings form starts it empty. */
  readonly cloud_init?: string;
};

/** One VM as `GET /api/vms` returns it. */
export type Vm = VmFields & NicSlots & ExtraDiskSlots;

/** The browser console needs an embedded SPICE (2) or VNC (3) display. */
const SPICE_DISPLAY = 2;
const VNC_DISPLAY = 3;

export const embeddedDisplayCapable = (vm: Vm): boolean =>
  vm.embed_display === "true" && (vm.display === SPICE_DISPLAY || vm.display === VNC_DISPLAY);

/** Configuration problems the summary and the dashboard's attention list report. */
export const vmWarnings = (vm: Vm): ReadonlyArray<string> => {
  const warnings: Array<string> = [];
  if (vm.embed_display === "true" && !embeddedDisplayCapable(vm)) {
    warnings.push("Embedded display is enabled, but browser console requires VNC or SPICE.");
  }
  if (vm.net === "none") {
    warnings.push("Network adapter is disconnected.");
  }
  if (vm.net === "gvproxy") {
    warnings.push("gvproxy networking requires a gvproxy daemon listening on /tmp/hangar-gvproxy-qemu.sock.");
  }
  if (vm.net === "bridge") {
    warnings.push("Bridged networking requires a configured host bridge (e.g. br0).");
  }
  return warnings;
};

const NETWORK_LABELS: Readonly<Record<string, string>> = {
  user: "NAT (user mode)",
  gvproxy: "gvproxy (user mode)",
  bridge: "Bridged",
  none: "Disconnected",
};

export const networkLabel = (vm: Vm): string => {
  const net = vm.net === "" ? "user" : vm.net;
  return NETWORK_LABELS[net] ?? net;
};

const DISPLAY_LABELS: ReadonlyArray<string> = ["GTK", "SDL", "SPICE", "VNC", "None"];
const GPU_LABELS: ReadonlyArray<string> = [
  "Virtio-GPU (virgl 3D)",
  "Virtio-VGA (virgl 3D)",
  "Virtio-GPU",
  "Virtio-VGA",
  "QXL",
  "Standard VGA",
];
const VIRGL_SUFFIX = " (virgl 3D)";

/** Video line of the summary: `Embedded VNC · Virtio-GPU · 2D`. */
export const videoSummary = (vm: Vm): string => {
  const display = DISPLAY_LABELS[vm.display] ?? "Display";
  const has3d = vm.enable_3d === "true";
  const gpu = GPU_LABELS[vm.gpu_device] ?? "GPU";
  const embed = vm.embed_display === "true" ? "Embedded" : "Native";
  return `${embed} ${display} · ${has3d ? gpu : gpu.replace(VIRGL_SUFFIX, "")} · ${has3d ? "3D accelerated" : "2D"}`;
};
