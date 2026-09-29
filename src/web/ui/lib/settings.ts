import { statusLabel } from "@/lib/format";
import type { Flag, Vm, VmStatus } from "@/lib/vm";

/** Form values by field key; every value is the text of its control. */
export type SettingValues = Readonly<Record<string, string>>;

/** NIC and extra-disk slot counts, served by `GET /api/capabilities`. */
export type HardwareSlots = { readonly nics: number; readonly extraDisks: number };

export type Option = { readonly value: string; readonly label: string };

export type Control =
  | { readonly kind: "text"; readonly placeholder?: string; readonly pattern?: string; readonly maxLength?: number }
  | { readonly kind: "number"; readonly min: number; readonly max: number; readonly step: number }
  | { readonly kind: "select"; readonly options: ReadonlyArray<Option> }
  | { readonly kind: "textarea"; readonly placeholder: string };

/** Buttons drawn under a field. Their `data-action` handlers live in `app.js`. */
export type FieldTools = "media" | "disk" | "disk2";

export type SettingField = {
  /** Request body key; the control id is `e_<key>`. */
  readonly key: string;
  readonly label: string;
  readonly control: Control;
  readonly required?: true;
  readonly tools?: FieldTools;
  /** Starting value from the VM. */
  readonly initial: (vm: Vm) => string;
};

export type SettingsSection = {
  readonly id: string;
  readonly title: string;
  readonly note: string;
  readonly fields: ReadonlyArray<SettingField>;
};

const options = (...pairs: ReadonlyArray<readonly [string, string]>): ReadonlyArray<Option> =>
  pairs.map(([value, label]) => ({ value, label }));

const YES_NO = options(["0", "No"], ["1", "Yes"]);
const DISK_FORMATS = options(["0", "QCOW2"], ["1", "Raw"], ["2", "VMDK"], ["3", "VDI"]);
const NIC_MODES = options(["none", "None"], ["user", "NAT"], ["gvproxy", "gvproxy"], ["bridge", "Bridged"]);
const CPU_MODEL_NAMES: ReadonlyArray<readonly [string, string]> = [
  ["host", "Host"],
  ["host-passthrough", "Host Passthrough"],
  ["max", "Max"],
  ["qemu64", "QEMU64"],
  ["kvm64", "KVM64"],
  ["EPYC", "EPYC"],
  ["EPYC-Rome", "EPYC-Rome"],
  ["EPYC-Milan", "EPYC-Milan"],
  ["Skylake-Server", "Skylake-Server"],
  ["Skylake-Client", "Skylake-Client"],
  ["Cascadelake-Server", "Cascadelake-Server"],
  ["Icelake-Server", "Icelake-Server"],
  ["Nehalem", "Nehalem"],
  ["Westmere", "Westmere"],
  ["SandyBridge", "SandyBridge"],
  ["IvyBridge", "IvyBridge"],
  ["Haswell", "Haswell"],
  ["Broadwell", "Broadwell"],
  ["Opteron_G5", "Opteron G5"],
  ["Cooperlake", "Cooperlake"],
  ["SapphireRapids", "SapphireRapids"],
  ["GraniteRapids", "GraniteRapids"],
  ["Neoverse-N1", "Neoverse-N1"],
  ["Neoverse-N2", "Neoverse-N2"],
  ["Neoverse-V1", "Neoverse-V1"],
  ["aarch64", "AArch64"],
];

const MAC_PATTERN = "([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}";

const text = (placeholder?: string): Control => (placeholder === undefined ? { kind: "text" } : { kind: "text", placeholder });
const macControl: Control = { kind: "text", pattern: MAC_PATTERN };
const num = (min: number, max: number): Control => ({ kind: "number", min, max, step: 1 });
const select = (choices: ReadonlyArray<Option>): Control => ({ kind: "select", options: choices });

const str = (stored: string | number | undefined): string => (stored === undefined ? "" : String(stored));
const orDefault = (stored: string | number | undefined, fallback: string | number): string =>
  stored === undefined || stored === "" || stored === 0 ? String(fallback) : String(stored);
const flag = (stored: Flag): string => (stored === "true" ? "1" : "0");

const MEM_MAX = 65_536;
const CPU_MAX = 256;
const SOCKETS_MAX = 64;
const DISK_MAX = 65_536;
const NAME_MAX = 80;
const PORT_MAX = 65_535;
const DISPLAYS_MAX = 16;
const AP_INTERVAL_MAX = 1440;
const AP_MAX_KEPT = 100;
const BITRATE_MAX = 50_000;
const BITRATE_STEP = 500;
const IO_THREADS_MAX = 64;
const BPS_MAX = 1_099_511_627_776;
const IOPS_MAX = 100_000_000;
const DEFAULT_MEM = 2048;
const DEFAULT_VNC_PORT = 5900;
const DEFAULT_SPICE_PORT = 5901;
const DEFAULT_DISK_GB = 20;
const DEFAULT_AP_INTERVAL = 60;
const DEFAULT_AP_KEPT = 10;

const BASIC_FIELDS: ReadonlyArray<SettingField> = [
  { key: "name", label: "Name", control: { kind: "text", maxLength: NAME_MAX }, required: true, initial: (vm) => vm.name },
  {
    key: "guest_os",
    label: "Guest OS",
    control: select(options(["0", "Linux"], ["1", "Windows"], ["2", "FreeBSD"], ["3", "macOS"], ["4", "Other"])),
    initial: (vm) => str(vm.guest_os),
  },
  { key: "mem", label: "Memory (MB)", control: num(128, MEM_MAX), required: true, initial: (vm) => orDefault(vm.mem, DEFAULT_MEM) },
  { key: "cpu", label: "CPU Cores", control: num(1, CPU_MAX), required: true, initial: (vm) => orDefault(vm.cpu, 2) },
  { key: "cpu_sockets", label: "CPU Sockets", control: num(1, SOCKETS_MAX), initial: (vm) => orDefault(vm.cpu_sockets, 1) },
  {
    key: "cpu_model",
    label: "CPU Model",
    control: select(options(...CPU_MODEL_NAMES)),
    initial: (vm) => orDefault(vm.cpu_model, "host"),
  },
  {
    key: "disk",
    label: "Disk Size (GB)",
    control: num(1, DISK_MAX),
    required: true,
    tools: "disk",
    initial: (vm) => orDefault(vm.disk, DEFAULT_DISK_GB),
  },
  { key: "disk_format", label: "Disk Format", control: select(DISK_FORMATS), initial: (vm) => str(vm.disk_format) },
  {
    key: "disk_cache",
    label: "Disk Cache",
    control: select(options(["0", "Writeback"], ["1", "Writethrough"], ["2", "None"], ["3", "Direct Sync"], ["4", "Unsafe"])),
    initial: (vm) => str(vm.disk_cache),
  },
  { key: "iso_path", label: "ISO Path", control: text(), tools: "media", initial: (vm) => vm.iso_path },
  { key: "firmware", label: "Firmware", control: select(options(["bios", "BIOS"], ["uefi", "UEFI"])), initial: (vm) => orDefault(vm.fw, "bios") },
  {
    key: "boot_order",
    label: "Boot Order",
    control: select(options(["0", "Hard Disk"], ["1", "CD/DVD"], ["2", "PXE"])),
    initial: (vm) => str(vm.boot_order),
  },
  { key: "rtc", label: "RTC Clock", control: select(options(["0", "UTC"], ["1", "Local time (Windows)"])), initial: (vm) => str(vm.rtc) },
];

const nicFields = (count: number): ReadonlyArray<SettingField> => {
  const fields: Array<SettingField> = [];
  for (let n = 2; n <= count; n += 1) {
    fields.push(
      { key: `nic${n}`, label: `NIC ${n}`, control: select(NIC_MODES), initial: (vm) => orDefault(vm[`nic${n}_mode`], "none") },
      { key: `nic${n}_mac`, label: `NIC ${n} MAC`, control: macControl, initial: (vm) => str(vm[`nic${n}_mac`]) },
      {
        key: `nic${n}_vnet`,
        label: `NIC ${n} VMnet`,
        control: text("virtual network name (optional)"),
        initial: (vm) => str(vm[`nic${n}_vnet`]),
      },
    );
  }
  return fields;
};

const NETWORK_FIELDS: ReadonlyArray<SettingField> = [
  {
    key: "network",
    label: "Network",
    control: select(options(["user", "NAT (User)"], ["gvproxy", "gvproxy (User)"], ["bridge", "Bridged"], ["none", "None"])),
    initial: (vm) => orDefault(vm.net, "user"),
  },
  {
    key: "vnet",
    label: "Virtual Network",
    control: text("bind to a virtual network name (optional)"),
    initial: (vm) => vm.vnet,
  },
  { key: "mac_address", label: "MAC Address", control: macControl, initial: (vm) => vm.mac },
];

const PORT_FORWARDS: SettingField = { key: "portfw", label: "Port Forwards", control: text(), initial: (vm) => vm.port_forwards };

const SHARING_FIELDS: ReadonlyArray<SettingField> = [
  { key: "shared_folder", label: "Shared Folder", control: text(), initial: (vm) => vm.shared_folder },
  { key: "usb", label: "USB Device", control: text(), initial: (vm) => vm.usb_device },
  {
    key: "usb_policy",
    label: "USB Policy",
    control: select(options(["0", "None"], ["1", "USB 2.0 (EHCI)"], ["2", "USB 3.0 (xHCI)"])),
    initial: (vm) => str(vm.usb_policy),
  },
  { key: "guest_tools", label: "Guest Tools", control: select(YES_NO), initial: (vm) => flag(vm.guest_tools) },
];

const AUTOPROTECT_FIELDS: ReadonlyArray<SettingField> = [
  { key: "autoprotect", label: "AutoProtect", control: select(options(["0", "Off"], ["1", "On"])), initial: (vm) => flag(vm.autoprotect) },
  {
    key: "ap_interval",
    label: "AP Interval",
    control: num(1, AP_INTERVAL_MAX),
    initial: (vm) => orDefault(vm.autoprotect_interval, DEFAULT_AP_INTERVAL),
  },
  { key: "ap_max", label: "AP Max", control: num(1, AP_MAX_KEPT), initial: (vm) => orDefault(vm.autoprotect_max, DEFAULT_AP_KEPT) },
];

const DISPLAY_FIELDS: ReadonlyArray<SettingField> = [
  {
    key: "display",
    label: "Display",
    control: select(options(["0", "GTK"], ["1", "SDL"], ["2", "SPICE"], ["3", "VNC"], ["4", "None"])),
    initial: (vm) => str(vm.display),
  },
  {
    key: "display_resolution",
    label: "Display Res",
    control: select(options(["0", "Auto"], ["1", "800x600"], ["2", "1024x768"], ["3", "1280x800"], ["4", "1920x1080"])),
    initial: (vm) => str(vm.display_resolution),
  },
  { key: "enable_3d", label: "3D Accel", control: select(YES_NO), initial: (vm) => flag(vm.enable_3d) },
  {
    key: "gpu_device",
    label: "GPU Device",
    control: select(
      options(["0", "Virtio-GPU (3D)"], ["1", "Virtio-VGA (3D)"], ["2", "Virtio-GPU"], ["3", "Virtio-VGA"], ["4", "QXL"], ["5", "Standard VGA"]),
    ),
    initial: (vm) => str(vm.gpu_device),
  },
  { key: "embed_display", label: "Embed Display", control: select(YES_NO), initial: (vm) => flag(vm.embed_display) },
  { key: "enable_serial", label: "Serial", control: select(YES_NO), initial: (vm) => flag(vm.hasSerial) },
  { key: "num_displays", label: "Num Displays", control: num(1, DISPLAYS_MAX), initial: (vm) => orDefault(vm.num_displays, 1) },
  { key: "vnc_port", label: "VNC Port", control: num(1, PORT_MAX), initial: (vm) => orDefault(vm.vnc_port, DEFAULT_VNC_PORT) },
  { key: "spice_port", label: "SPICE Port", control: num(1, PORT_MAX), initial: (vm) => orDefault(vm.spice_port, DEFAULT_SPICE_PORT) },
  {
    key: "accel",
    label: "Accelerator",
    control: select(
      options(["auto", "Auto (best available)"], ["tcg", "TCG (software)"], ["kvm", "KVM (Linux)"], ["hvf", "HVF (macOS)"], ["whpx", "WHPX (Windows)"]),
    ),
    initial: (vm) => orDefault(vm.accel, "auto"),
  },
  { key: "audio", label: "Audio", control: select(options(["0", "None"], ["1", "Intel HDA"], ["2", "AC97"])), initial: (vm) => str(vm.audio) },
  { key: "video_stream", label: "Video Stream (experimental)", control: select(YES_NO), initial: (vm) => flag(vm.video_stream) },
  {
    key: "video_bitrate",
    label: "Video Bitrate (kbps, 0=auto)",
    control: { kind: "number", min: 0, max: BITRATE_MAX, step: BITRATE_STEP },
    initial: (vm) => str(vm.video_bitrate_kbps),
  },
];

const STORAGE_FIELDS: ReadonlyArray<SettingField> = [
  { key: "disk2_path", label: "Disk 2 Path", control: text(), tools: "disk2", initial: (vm) => vm.disk2_path },
  { key: "disk2_size", label: "Disk 2 Size", control: num(0, DISK_MAX), initial: (vm) => str(vm.disk2_size) },
  { key: "disk2_format", label: "Disk 2 Format", control: select(DISK_FORMATS), initial: (vm) => str(vm.disk2_format) },
  { key: "floppy", label: "Floppy", control: text(), initial: (vm) => vm.floppy_path },
  { key: "favorite", label: "Favorite", control: select(YES_NO), initial: (vm) => flag(vm.favorite) },
  { key: "notes", label: "Notes", control: text(), initial: (vm) => vm.notes },
  { key: "tags", label: "Tags", control: text("comma-separated, e.g. prod, web"), initial: (vm) => vm.tags },
  {
    key: "cloud_init",
    label: "Cloud-Init User-Data",
    control: { kind: "textarea", placeholder: "#cloud-config\n… (NoCloud user-data; attached as a seed ISO)" },
    initial: (vm) => str(vm.cloud_init),
  },
];

const extraDiskFields = (count: number): ReadonlyArray<SettingField> => {
  const fields: Array<SettingField> = [];
  for (let n = 0; n < count; n += 1) {
    fields.push(
      { key: `extra${n}_path`, label: `Extra ${n} Path`, control: text(), initial: (vm) => str(vm[`extra${n}_path`]) },
      { key: `extra${n}_size`, label: `Extra ${n} Size`, control: num(0, DISK_MAX), initial: (vm) => orDefault(vm[`extra${n}_size`], 0) },
      {
        key: `extra${n}_format`,
        label: `Extra ${n} Format`,
        control: select(DISK_FORMATS),
        initial: (vm) => orDefault(vm[`extra${n}_format`], 0),
      },
    );
  }
  return fields;
};

const ADVANCED_FIELDS: ReadonlyArray<SettingField> = [
  { key: "guest_agent", label: "Guest Agent", control: select(YES_NO), initial: (vm) => flag(vm.guest_agent) },
  { key: "virtio_rng", label: "virtio-rng Entropy", control: select(YES_NO), initial: (vm) => flag(vm.virtio_rng) },
  { key: "tpm", label: "TPM", control: select(YES_NO), initial: (vm) => flag(vm.tpm) },
  { key: "secure_boot", label: "Secure Boot", control: select(YES_NO), initial: (vm) => flag(vm.secure_boot) },
  { key: "hyperv_enlightenments", label: "Hyper-V Enlightenments", control: select(YES_NO), initial: (vm) => flag(vm.hyperv_enlightenments) },
  { key: "hugepages", label: "Hugepages", control: select(YES_NO), initial: (vm) => flag(vm.hugepages) },
  {
    key: "watchdog",
    label: "Watchdog",
    control: select(options(["0", "None"], ["1", "Reset Guest"], ["2", "Power Off Guest"], ["3", "Pause Guest"])),
    initial: (vm) => str(vm.watchdog),
  },
  { key: "ballooning", label: "Ballooning", control: select(YES_NO), initial: (vm) => flag(vm.ballooning) },
  { key: "host_autostart", label: "Host Autostart", control: select(YES_NO), initial: (vm) => flag(vm.host_autostart) },
  { key: "io_threads", label: "I/O Threads", control: num(0, IO_THREADS_MAX), initial: (vm) => str(vm.io_threads) },
  {
    key: "disk_bps_throttle",
    label: "Disk Throttle (bytes/s, 0 = off)",
    control: num(0, BPS_MAX),
    initial: (vm) => str(vm.disk_bps_throttle),
  },
  {
    key: "disk_iops_throttle",
    label: "Disk Throttle (IOPS, 0 = off)",
    control: num(0, IOPS_MAX),
    initial: (vm) => str(vm.disk_iops_throttle),
  },
];

/** Left-nav sections in display order. NIC and extra-disk rows follow the daemon's slot counts. */
export const buildSections = ({ nics, extraDisks }: HardwareSlots): ReadonlyArray<SettingsSection> => [
  { id: "basic", title: "Basic", note: "Identity, operating system, firmware, and boot defaults.", fields: BASIC_FIELDS },
  {
    id: "network_and_boot",
    title: "Network & Boot",
    note: "VMnet, NAT, bridged adapters, MAC addresses, and port forwarding.",
    fields: [...NETWORK_FIELDS, ...nicFields(nics), PORT_FORWARDS],
  },
  { id: "sharing", title: "Sharing", note: "Guest integration, shared folders, and USB policy.", fields: SHARING_FIELDS },
  { id: "autoprotect", title: "AutoProtect", note: "Automatic snapshot scheduling for this VM.", fields: AUTOPROTECT_FIELDS },
  {
    id: "display_and_video",
    title: "Display & Video",
    note: "Browser console, SPICE/VNC, virgl, display ports, serial, audio.",
    fields: DISPLAY_FIELDS,
  },
  {
    id: "storage_and_notes",
    title: "Storage & Notes",
    note: "Secondary storage, removable media, notes, tags, and cloud-init.",
    fields: STORAGE_FIELDS,
  },
  {
    id: "extra_disks",
    title: "Extra Disks",
    note: "Additional virtual disks exposed to the guest.",
    fields: extraDiskFields(extraDisks),
  },
  { id: "advanced", title: "Advanced", note: "Advanced QEMU capabilities and performance controls.", fields: ADVANCED_FIELDS },
];

/**
 * Order of the request body. The daemon reads keys by name; the order is kept so the payload stays
 * identical to what the form has always sent.
 */
const BODY_KEYS: ReadonlyArray<string> = [
  "name", "mem", "cpu", "cpu_sockets", "cpu_model", "disk", "disk_format", "disk_cache", "iso_path", "mac_address", "network",
  "vnet", "firmware", "shared_folder", "usb", "usb_policy", "guest_tools", "autoprotect", "ap_interval", "ap_max", "disk2_path",
  "disk2_size", "disk2_format", "floppy", "portfw", "notes", "tags", "cloud_init", "enable_3d", "gpu_device", "display",
  "display_resolution", "guest_os", "audio", "boot_order", "rtc", "accel", "embed_display", "vnc_port", "spice_port",
  "enable_serial", "num_displays", "favorite", "guest_agent", "virtio_rng", "tpm", "secure_boot", "hyperv_enlightenments",
  "hugepages", "watchdog", "ballooning", "host_autostart", "io_threads", "disk_bps_throttle", "disk_iops_throttle",
  "video_stream", "video_bitrate",
];

/** Every key in request-body order for the given slot counts. */
export const bodyKeys = ({ nics, extraDisks }: HardwareSlots): ReadonlyArray<string> => {
  const keys = [...BODY_KEYS];
  for (let n = 2; n <= nics; n += 1) {
    keys.push(`nic${n}`, `nic${n}_mac`, `nic${n}_vnet`);
  }
  for (let n = 0; n < extraDisks; n += 1) {
    keys.push(`extra${n}_path`, `extra${n}_size`, `extra${n}_format`);
  }
  return keys;
};

/**
 * Starting values from the VM. A select whose stored value is not among its options starts on the
 * first option, the same as the browser would show and save.
 */
export const initialValues = (vm: Vm, sections: ReadonlyArray<SettingsSection>): SettingValues => {
  const values: Record<string, string> = {};
  for (const { fields } of sections) {
    for (const field of fields) {
      const stored = field.initial(vm);
      const { control } = field;
      values[field.key] =
        control.kind === "select" && !control.options.some((choice) => choice.value === stored)
          ? (control.options[0]?.value ?? "")
          : stored;
    }
  }
  return values;
};

/** URL-encoded form body sent to `POST /api/vms/<index>`. */
export const settingsBody = (values: SettingValues, slots: HardwareSlots): string =>
  bodyKeys(slots)
    .map((key) => `${key}=${encodeURIComponent(values[key] ?? "")}`)
    .join("&");

/** True when any value differs from where the form started. */
export const isDirty = (values: SettingValues, initial: SettingValues): boolean =>
  Object.keys(initial).some((key) => values[key] !== initial[key]);

export type Issue = { readonly message: string; readonly severity: "error" | "warning" };

/** Issues by field key. */
export type Issues = Readonly<Record<string, Issue>>;

const MAC_FULL = /^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$/u;
const PORT_FORWARD_PAIRS = /^\s*\d{1,5}:\d{1,5}(\s*,\s*\d{1,5}:\d{1,5})*\s*$/u;
const PORT_FORWARD_HOSTS = /^\s*\d{1,5}:[^,]+:\d{1,5}(\s*,\s*\d{1,5}:[^,]+:\d{1,5})*\s*$/u;
const SPICE = "2";
const VNC = "3";
const VIRGL_GPUS: ReadonlySet<string> = new Set(["0", "1"]);
const DECIMAL = 10;

const RANGES: ReadonlyArray<{ readonly key: string; readonly min: number; readonly max: number; readonly message: string }> = [
  { key: "mem", min: 128, max: MEM_MAX, message: "Memory must be 128-65536 MB." },
  { key: "cpu", min: 1, max: CPU_MAX, message: "CPU cores must be 1-256." },
  { key: "disk", min: 1, max: DISK_MAX, message: "Disk size must be 1-65536 GB." },
];

const outOfRange = (entry: string, min: number, max: number): boolean => {
  const parsed = Number.parseInt(entry, DECIMAL);
  return !Number.isFinite(parsed) || parsed < min || parsed > max;
};

const error = (message: string): Issue => ({ message, severity: "error" });

/** Blocking errors and advisory warnings for the form. Only errors stop a save. */
export const validateSettings = (values: SettingValues, slots: HardwareSlots): Issues => {
  const at = (key: string): string => values[key] ?? "";
  const issues: Record<string, Issue> = {};
  if (at("name").trim() === "") {
    issues.name = error("Name is required.");
  }
  for (const { key, min, max, message } of RANGES) {
    if (outOfRange(at(key), min, max)) {
      issues[key] = error(message);
    }
  }
  const macKeys = ["mac_address", ...Array.from({ length: Math.max(0, slots.nics - 1) }, (_, i) => `nic${i + 2}_mac`)];
  for (const key of macKeys) {
    const mac = at(key).trim();
    if (mac !== "" && !MAC_FULL.test(mac)) {
      issues[key] = error("Use XX:XX:XX:XX:XX:XX.");
    }
  }
  for (const key of ["vnc_port", "spice_port"]) {
    if (outOfRange(at(key), 1, PORT_MAX)) {
      issues[key] = error("Port must be 1-65535.");
    }
  }
  const forwards = at("portfw").trim();
  if (forwards !== "" && !PORT_FORWARD_PAIRS.test(forwards) && !PORT_FORWARD_HOSTS.test(forwards)) {
    issues.portfw = error("Use host:guest or host:ip:guest entries.");
  }
  const embedded = at("embed_display") === "1";
  if (embedded && at("display") !== SPICE && at("display") !== VNC) {
    issues.display = {
      message: "Browser console requires SPICE or VNC; native display opens outside the browser.",
      severity: "warning",
    };
  }
  if (embedded && at("display") === VNC && at("enable_3d") === "1" && VIRGL_GPUS.has(at("gpu_device"))) {
    issues.gpu_device = {
      message: "Virgl 3D needs embedded SPICE; VNC will fall back to non-GL virtio.",
      severity: "warning",
    };
  }
  return issues;
};

/** Where a blocking error first shows in nav order: the field to focus and the section that holds it. */
export const firstError = (
  sections: ReadonlyArray<SettingsSection>,
  issues: Issues,
): { readonly key: string; readonly section: string } | null => {
  for (const { id, fields } of sections) {
    const bad = fields.find((field) => issues[field.key]?.severity === "error");
    if (bad !== undefined) {
      return { key: bad.key, section: id };
    }
  }
  return null;
};

const LOCKED_STATUSES: ReadonlySet<VmStatus> = new Set(["running", "paused", "suspended"]);

/** Fields that stay editable while the VM has live or saved state. */
const EDITABLE_WHILE_LOCKED: ReadonlySet<string> = new Set([
  "name", "notes", "tags", "vnet", "favorite", "autoprotect", "ap_interval", "ap_max",
]);

/** Virtual hardware cannot change while the VM has live or saved state. */
export const hardwareLocked = (status: VmStatus): boolean => LOCKED_STATUSES.has(status);

export const fieldLocked = (key: string, status: VmStatus): boolean => hardwareLocked(status) && !EDITABLE_WHILE_LOCKED.has(key);

export const lockNotice = (status: VmStatus): string =>
  `This VM is ${statusLabel(status).toLowerCase()}: virtual hardware is locked. Name, notes, tags, folder and AutoProtect stay editable; CD/ISO can be changed live.`;
