import { syncShell } from "@/app/feedback";
import { uiHandlers } from "@/app/handlers";
import { listenKeyboard } from "@/app/keyboard";
import { POLL_INTERVAL_MS, refresh } from "@/app/poll";
import { onViewportChange } from "@/app/sidebar";
import { state } from "@/app/state";
import { renderList, syncPanels } from "@/app/view";
import { ui } from "@/bridge";
import { loadFolderState } from "@/lib/folders";
import { initTheme } from "@/lib/theme";
import { parseCapabilities } from "@/lib/wire";

/** A burst of change events collapses into one refresh this long after the last. */
const EVENT_REFRESH_DELAY_MS = 120;

/** Slot limits come from the daemon (`vm.zig` constants); the defaults hold until it answers. */
const loadSlots = (): void => {
  fetch("/api/capabilities")
    .then((response) => response.json())
    .then((body: unknown) => {
      const { maxNics, maxExtraDisks } = parseCapabilities(body);
      state.slots = { nics: maxNics || state.slots.nics, extraDisks: maxExtraDisks || state.slots.extraDisks };
    })
    .catch(() => undefined);
};

/**
 * The daemon bumps a state version on every mutation and unexpected VM exit, and pushes it here, so a
 * change shows at once instead of on the next poll. EventSource reconnects on its own; the poll stays
 * as the fallback.
 */
const listenForChanges = (): void => {
  const events = new EventSource("/api/events");
  const pending: { timer: ReturnType<typeof setTimeout> | null } = { timer: null };
  events.addEventListener("open", () => {
    state.streamLive = true;
    syncShell();
  });
  events.addEventListener("error", () => {
    state.streamLive = false;
    syncShell();
  });
  events.addEventListener("change", () => {
    if (pending.timer !== null) {
      clearTimeout(pending.timer);
    }
    pending.timer = setTimeout(() => void refresh(), EVENT_REFRESH_DELAY_MS);
  });
};

/** Draws the page, wires the shortcuts and the daemon feeds, and starts the poll. */
export const start = async (): Promise<void> => {
  await Promise.all([initTheme(), loadFolderState()]);
  ui.mount(uiHandlers);
  syncShell();
  renderList();
  syncPanels();
  loadSlots();
  listenKeyboard();
  globalThis.addEventListener("resize", onViewportChange);
  globalThis.addEventListener("beforeunload", () => {
    ui.stopDisplay();
    ui.stopSerial(true);
  });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      void refresh();
    }
  });
  void refresh();
  setInterval(() => void refresh(), POLL_INTERVAL_MS);
  listenForChanges();
};
