import { apiPost } from "@/app/api";
import { setStatus, showToast } from "@/app/feedback";
import { cloneVm, createVm, importVm, quickstartVm } from "@/app/library";
import { select } from "@/app/session";
import { indexOfName, selectedVm, state } from "@/app/state";
import { ui } from "@/bridge";
import { AUTH_HEADERS, messageOf, responseError } from "@/lib/api";
import { ensureAsset } from "@/lib/assets";
import { statusLabel } from "@/lib/format";
import { parseCatalog } from "@/lib/catalog";
import { prefsValues } from "@/lib/prefs";
import { parseSnapshotList } from "@/lib/snapshots";
import { currentTheme } from "@/lib/theme";
import { buildTopologyGraph, topologyLayout, type ElkEngine } from "@/lib/topology";
import { parseVnets, type Vnet } from "@/lib/vnet";
import { parseCapabilities } from "@/lib/wire";

const enc = encodeURIComponent;

export const newVm = (): void => ui.openNewVm({ create: createVm });

export const importGuest = (): void => {
  ui.openImport({ importVm });
};

export const cloneGuest = (): void => {
  const vm = selectedVm();
  if (vm !== null) {
    ui.openClone({ vmName: vm.name, clone: cloneVm });
  }
};

export const showShortcuts = (): void => ui.openShortcuts();

// ── Migrate ──────────────────────────────────────────────────────────

export const migrateGuest = (): void => {
  const vm = selectedVm();
  if (vm === null) {
    return;
  }
  ui.openMigrate({
    vmName: vm.name,
    start: (host, port) => {
      const { selected } = state;
      const current = selectedVm();
      return selected === null || current === null ? Promise.resolve(false) : ui.startMigration(current.id, selected, `tcp:${host}:${port}`);
    },
  });
};

// ── Snapshots ────────────────────────────────────────────────────────

const snapshotMeta = () => {
  const vm = selectedVm();
  return { vmName: vm?.name ?? "", statusLabel: vm === null ? "" : statusLabel(vm.status), running: vm?.status === "running" || vm?.status === "paused" };
};

const loadSnapshots = async (): Promise<void> => {
  const index = state.selected;
  if (index === null) {
    return;
  }
  const meta = snapshotMeta();
  const response = await fetch(`/api/vms/${index}/snapshots`).catch((): null => null);
  const text = response?.ok === true ? await response.text().catch((): null => null) : null;
  ui.setSnapshots({ ...meta, list: text === null ? { kind: "failed" } : { kind: "ready", items: parseSnapshotList(text) } });
};

const takeSnapshot = async (tag: string): Promise<boolean> => {
  const index = state.selected;
  if (index === null) {
    showToast("No VM selected", "warn");
    return false;
  }
  if ((await apiPost(`/api/vms/${index}/snapshots`, `tag=${enc(tag)}`)) === null) {
    return false;
  }
  void loadSnapshots();
  setStatus(`Snapshot taken: ${tag}`);
  return true;
};

const revertSnapshot = async (tag: string): Promise<boolean> => {
  const index = state.selected;
  if (index === null || tag === "" || !(await ui.confirm(`Revert to snapshot "${tag}"? This will discard current state.`, { danger: true, okLabel: "Revert" }))) {
    return false;
  }
  if ((await apiPost(`/api/vms/${index}/snapshots/revert`, `tag=${enc(tag)}`)) === null) {
    void loadSnapshots();
    return false;
  }
  setStatus(`Reverted to snapshot: ${tag}`);
  return true;
};

const deleteSnapshot = async (tag: string): Promise<void> => {
  const index = state.selected;
  if (index === null || tag === "" || !(await ui.confirm(`Delete snapshot "${tag}"?`, { danger: true, okLabel: "Delete" }))) {
    return;
  }
  if (await apiPost(`/api/vms/${index}/snapshots/delete`, `tag=${enc(tag)}`)) {
    void loadSnapshots();
    setStatus(`Deleted snapshot: ${tag}`);
  }
};

/** Opens the Snapshot Manager for the selected VM and loads its list. */
export const openSnapshots = (): void => {
  if (state.selected === null) {
    return;
  }
  ui.openSnapshots({ ...snapshotMeta(), list: { kind: "loading" }, take: takeSnapshot, revert: revertSnapshot, remove: deleteSnapshot });
  void loadSnapshots();
};

// ── QEMU log ─────────────────────────────────────────────────────────

const loadLog = async (index: number): Promise<void> => {
  ui.setLog("Loading…");
  const response = await fetch(`/api/vms/${index}/log`, { headers: AUTH_HEADERS }).catch((error: unknown) => error);
  if (!(response instanceof Response)) {
    ui.setLog(`Failed to load log: ${messageOf(response, "request failed")}`);
  } else if (response.status === 404) {
    ui.setLog("No log output yet from this VM.");
  } else if (response.ok) {
    const text = await response.text();
    ui.setLog(text === "" ? "(log is empty)" : text);
  } else {
    ui.setLog(`Failed to load log: ${await responseError(response)}`);
  }
};

export const viewLog = (): void => {
  const vm = selectedVm();
  const index = state.selected;
  if (vm === null || index === null) {
    return;
  }
  ui.openLog(vm.name, () => {
    if (state.selected !== null) {
      void loadLog(state.selected);
    }
  });
  void loadLog(index);
};

// ── Preferences and About ────────────────────────────────────────────

/** The stored config, or null when there is none (a fresh daemon) or it cannot be read; the form then starts from the defaults. */
const fetchConfig = async (): Promise<unknown> => {
  const response = await fetch("/api/config").catch((): null => null);
  return response?.ok === true ? response.json().catch((): null => null) : null;
};

export const openPrefs = async (): Promise<void> => {
  ui.openPrefs({
    values: prefsValues(await fetchConfig(), currentTheme()),
    save: async (body) => {
      if ((await apiPost("/api/config", body)) === null) {
        return false;
      }
      setStatus("Preferences saved.");
      return true;
    },
  });
};

export const openAbout = (): void => {
  ui.openAbout();
  fetch("/api/capabilities")
    .then((response) => response.json())
    .then((body: unknown) => {
      const { version, maxVms } = parseCapabilities(body);
      ui.setAboutVersion(`Version ${version || "?"} \u00B7 up to ${maxVms || "?"} VMs`);
    })
    .catch(() => undefined);
};

// ── Catalog ──────────────────────────────────────────────────────────

export const openCatalog = async (): Promise<void> => {
  if (document.querySelector("#catalogdlg") !== null) {
    return;
  }
  ui.openCatalog({ list: { kind: "loading" }, create: quickstartVm });
  const response = await fetch("/api/catalog").catch((): null => null);
  const body: unknown = response?.ok === true ? await response.json().catch((): undefined => undefined) : undefined;
  if (body === undefined) {
    ui.setCatalog({ list: { kind: "failed" } });
    return;
  }
  const items = parseCatalog(body);
  ui.setCatalog({ list: items.length > 0 ? { kind: "ready", items } : { kind: "empty" } });
};

// ── Virtual networks and their topology ──────────────────────────────

/** The daemon's networks, or null when they could not be loaded (a failed load must never be saved back as an empty set). */
const loadVnets = async (): Promise<Array<Vnet> | null> => {
  const response = await fetch("/api/networks").catch((): null => null);
  const body: unknown = response?.ok === true ? await response.json().catch((): undefined => undefined) : undefined;
  return parseVnets(body);
};

/** Writes the whole network set; `saved` names the network for Save Selected. */
const saveVnets = async (networks: ReadonlyArray<Vnet>, saved: string | null): Promise<boolean> => {
  if ((await apiPost("/api/networks", JSON.stringify({ networks }))) === null) {
    return false;
  }
  setStatus(saved === null ? "VNet settings saved." : `Saved "${saved}".`);
  return true;
};

const ELK_SRC = "/elk.js";

const closeDialog = (id: string): void => {
  document.querySelector<HTMLDialogElement>(`#${id}`)?.close();
};

/** The layout engine, loaded on first use; null (after showing the failure) when its bundle does not arrive. */
const loadEngine = async (): Promise<(new () => ElkEngine) | null> => {
  if (globalThis.ELK === undefined) {
    ui.setTopology({ view: { kind: "loading", message: "Loading layout engine…" } });
    const failure = await ensureAsset(ELK_SRC, () => globalThis.ELK !== undefined).then(
      (): null => null,
      (error: unknown) => messageOf(error, "load failed"),
    );
    if (failure !== null) {
      ui.setTopology({ view: { kind: "failed", message: "Layout engine failed to load." } });
      return null;
    }
  }
  return globalThis.ELK ?? null;
};

/** Every step pushes a view to the dialog: loading (engine, then layout), failed (Retry), empty or ready. */
const renderTopology = async (): Promise<void> => {
  const Engine = await loadEngine();
  if (Engine === null) {
    return;
  }
  const built = buildTopologyGraph(state.vms, (await loadVnets()) ?? []);
  if (built.graph.children.length === 0) {
    ui.setTopology({ view: { kind: "empty" } });
    return;
  }
  ui.setTopology({ view: { kind: "loading", message: "Computing layout…" } });
  await new Engine()
    .layout(built.graph)
    .then((placed) => ui.setTopology({ view: { kind: "ready", layout: topologyLayout(placed, built.meta) } }))
    .catch((error: unknown) => ui.setTopology({ view: { kind: "failed", message: `Layout failed: ${messageOf(error, "error")}` } }));
};

/** The editor's Topology button and the topology's network nodes open each other. */
const networkDialogs = {
  openVnets: async (focus?: string): Promise<void> => {
    if (document.querySelector("#vnetdlg") !== null) {
      if (focus !== undefined) {
        ui.selectVnet(focus);
      }
      return;
    }
    const networks = await loadVnets();
    if (networks === null) {
      showToast("Failed to load virtual networks", "error");
      return;
    }
    ui.openVnets({
      networks,
      select: focus === undefined ? undefined : { name: focus },
      save: saveVnets,
      confirmDiscard: () => ui.confirm("Discard unsaved network changes?", { danger: true, okLabel: "Discard" }),
      openTopology: () => void networkDialogs.openTopology(),
    });
  },
  openTopology: async (): Promise<void> => {
    if (document.querySelector("#topodlg") === null) {
      ui.openTopology({
        view: { kind: "loading", message: "Computing layout…" },
        open: (target) => {
          closeDialog("topodlg");
          if (target.kind === "vm") {
            closeDialog("vnetdlg");
            const index = indexOfName(target.name);
            if (index >= 0) {
              void select(index);
            }
          } else {
            void networkDialogs.openVnets(target.name);
          }
        },
        refresh: () => void renderTopology(),
      });
    }
    await renderTopology();
  },
};

export const { openVnets, openTopology } = networkDialogs;
