import { isNarrowLayout, syncShell } from "@/app/feedback";
import { state } from "@/app/state";

/** Opens or closes the sidebar: an overlay on narrow screens, a collapsed column on wide ones. */
export const toggleSidebar = (): void => {
  if (isNarrowLayout()) {
    state.sidebarOpen = !state.sidebarOpen;
  } else {
    state.sidebarOpen = false;
    state.sidebarCollapsed = !state.sidebarCollapsed;
  }
  syncShell();
};

/** Closes the overlay sidebar (after a selection); wide layouts keep their column. */
export const closeSidebar = (): void => {
  if (isNarrowLayout() && state.sidebarOpen) {
    state.sidebarOpen = false;
  }
  syncShell();
};

/** Wide layouts have no overlay: leaving the narrow layout closes it. */
export const onViewportChange = (): void => {
  if (!isNarrowLayout()) {
    state.sidebarOpen = false;
  }
  syncShell();
};
