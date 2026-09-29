import type { PrefsValues } from "@/components/dialogs/prefs";

const DEFAULT_MEMORY_MB = 2048;
const DEFAULT_CPU_CORES = 2;
const DEFAULT_AUTOPROTECT_MINUTES = 60;
const DEFAULT_AUTOPROTECT_KEEP = 10;

/** The stored preferences of `GET /api/config`; every field may be absent. */
type Stored = {
  readonly vmDir: string;
  readonly memoryMb: number;
  readonly cpuCores: number;
  readonly autoprotect: boolean;
  readonly autoprotectMinutes: number;
  readonly autoprotectKeep: number;
};

const storedPrefs = (config: unknown): Stored => {
  const prefs = typeof config === "object" && config !== null && "prefs" in config && typeof config.prefs === "object" && config.prefs !== null ? config.prefs : {};
  return {
    vmDir: "default_vm_dir" in prefs && typeof prefs.default_vm_dir === "string" ? prefs.default_vm_dir : "",
    memoryMb: "default_memory_mb" in prefs && typeof prefs.default_memory_mb === "number" ? prefs.default_memory_mb : 0,
    cpuCores: "default_cpu_cores" in prefs && typeof prefs.default_cpu_cores === "number" ? prefs.default_cpu_cores : 0,
    autoprotect: "autoprotect_enabled_default" in prefs && prefs.autoprotect_enabled_default === true,
    autoprotectMinutes:
      "autoprotect_interval_min_default" in prefs && typeof prefs.autoprotect_interval_min_default === "number" ? prefs.autoprotect_interval_min_default : 0,
    autoprotectKeep: "autoprotect_max_default" in prefs && typeof prefs.autoprotect_max_default === "number" ? prefs.autoprotect_max_default : 0,
  };
};

/**
 * The Preferences form values from `GET /api/config`. A missing or zero number takes the built-in
 * default; a missing theme takes `activeTheme` (the theme in effect).
 */
export const prefsValues = (config: unknown, activeTheme: string): PrefsValues => {
  const stored = storedPrefs(config);
  const theme = typeof config === "object" && config !== null && "theme" in config && typeof config.theme === "string" ? config.theme : "";
  return {
    theme: theme || activeTheme,
    defaultVmDir: stored.vmDir,
    defaultMemoryMb: String(stored.memoryMb || DEFAULT_MEMORY_MB),
    defaultCpuCores: String(stored.cpuCores || DEFAULT_CPU_CORES),
    autoprotectEnabled: stored.autoprotect ? "1" : "0",
    autoprotectIntervalMin: String(stored.autoprotectMinutes || DEFAULT_AUTOPROTECT_MINUTES),
    autoprotectMax: String(stored.autoprotectKeep || DEFAULT_AUTOPROTECT_KEEP),
  };
};
