import { embeddedDisplayCapable, type Vm } from "@/lib/vm";

/** Availability rules the toolbar, the context menu and the console buttons share. */
export type VmAction =
  | "settings"
  | "rename"
  | "clone"
  | "export"
  | "delete"
  | "snapshot"
  | "power-toggle"
  | "power-on"
  | "shutdown"
  | "reset"
  | "pause"
  | "suspend"
  | "cad"
  | "migrate"
  | "resume"
  | "hard-power"
  | "display"
  | "serial"
  | "batch-start"
  | "batch-stop";

const isRunning = (vm: Vm | null): boolean => vm?.status === "running";
const isPaused = (vm: Vm | null): boolean => vm?.status === "paused";

/** Actions that only need a selected VM. */
const NEEDS_VM: ReadonlySet<VmAction> = new Set(["settings", "rename", "clone", "export", "delete", "snapshot", "power-toggle"]);
/** Actions on a live guest. */
const NEEDS_RUNNING: ReadonlySet<VmAction> = new Set(["shutdown", "reset", "pause", "suspend", "cad", "migrate"]);

/** Whether `action` applies to `vm` (the selected VM, or null) given the whole inventory. */
export const actionAllowed = (action: VmAction, vm: Vm | null, inventory: ReadonlyArray<Vm>): boolean => {
  if (NEEDS_VM.has(action)) {
    return vm !== null;
  }
  if (NEEDS_RUNNING.has(action)) {
    return isRunning(vm);
  }
  const rules: Readonly<Partial<Record<VmAction, () => boolean>>> = {
    "power-on": () => vm !== null && !isRunning(vm) && !isPaused(vm),
    resume: () => isPaused(vm),
    "hard-power": () => isRunning(vm) || isPaused(vm),
    display: () => vm !== null && isRunning(vm) && embeddedDisplayCapable(vm),
    serial: () => vm !== null && isRunning(vm) && vm.hasSerial === "true",
    "batch-start": () => inventory.some((item) => item.status === "stopped" || item.status === "suspended"),
    "batch-stop": () => inventory.some((item) => item.status === "running" || item.status === "paused"),
  };
  return rules[action]?.() ?? true;
};

const REASONS: Readonly<Record<string, string>> = {
  display: "Requires a running VM with embedded VNC or SPICE display",
  serial: "Requires a running VM with serial enabled",
  resume: "Only paused or suspended VMs can resume",
  shutdown: "Requires a running VM",
  reset: "Requires a running VM",
  pause: "Requires a running VM",
  suspend: "Requires a running VM",
  cad: "Requires a running VM",
  migrate: "Requires a running VM",
  "hard-power": "Requires a running or paused VM",
  "power-on": "VM is already running",
  "batch-start": "No stopped VMs",
  "batch-stop": "No running VMs",
};

const NO_VM_REASON = "Select a VM first";
const UNAVAILABLE = "Unavailable";

/** Why `action` is off; call it only when `actionAllowed` said no. */
export const disabledReason = (action: VmAction, vm: Vm | null): string => {
  if (vm === null && action !== "batch-start" && action !== "batch-stop") {
    return NO_VM_REASON;
  }
  return REASONS[action] ?? UNAVAILABLE;
};

/** `null` when `action` works, else the reason it does not. */
export const actionReason = (action: VmAction, vm: Vm | null, inventory: ReadonlyArray<Vm>): string | null =>
  actionAllowed(action, vm, inventory) ? null : disabledReason(action, vm);
