export type Theme = "system" | "light" | "dark";

export const THEMES: ReadonlyArray<Theme> = ["system", "light", "dark"];

const STORAGE_KEY = "hangar-theme";
const DEFAULT_THEME: Theme = "dark";
const LIGHT_QUERY = "(prefers-color-scheme: light)";

export const isTheme = (candidate: unknown): candidate is Theme => THEMES.some((theme) => theme === candidate);

/** The theme after `current` in the cycle system, light, dark. */
export const nextTheme = (current: Theme): Theme => THEMES[(THEMES.indexOf(current) + 1) % THEMES.length] ?? DEFAULT_THEME;

/** Whether `theme` draws the light palette; `system` follows the OS preference. */
export const isLight = (theme: Theme, systemPrefersLight: boolean): boolean => theme === "light" || (theme === "system" && systemPrefersLight);

/** Accessible name of the toolbar toggle: the active theme and what a click does. */
export const themeLabel = (theme: Theme): string => `Theme: ${theme.charAt(0).toUpperCase()}${theme.slice(1)} (click to change)`;

type Listener = (theme: Theme) => void;

const listeners = new Set<Listener>();
const active: { theme: Theme } = { theme: DEFAULT_THEME };

const paint = (theme: Theme): void => {
  const root = document.documentElement;
  root.classList.toggle("light", isLight(theme, globalThis.matchMedia(LIGHT_QUERY).matches));
  root.classList.toggle("dark", theme === "dark");
};

export const currentTheme = (): Theme => active.theme;

/** Applies a theme, remembers it where storage allows, and tells the subscribers. */
export const applyTheme = (theme: Theme): void => {
  active.theme = theme;
  paint(theme);
  Promise.resolve()
    .then(() => localStorage.setItem(STORAGE_KEY, theme))
    .catch(() => undefined);
  for (const listener of listeners) {
    listener(theme);
  }
};

/** Moves to the next theme in the cycle and returns it. */
export const cycleTheme = (): Theme => {
  applyTheme(nextTheme(active.theme));
  return active.theme;
};

/** Calls `listener` after every theme change; returns the unsubscribe function. */
export const subscribeTheme = (listener: Listener): (() => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

/** Reads the remembered theme (dark when storage is blocked or empty), paints it, and repaints when the OS preference changes under `system`. */
export const initTheme = async (): Promise<void> => {
  const stored = await Promise.resolve()
    .then(() => localStorage.getItem(STORAGE_KEY))
    .catch(() => null);
  active.theme = isTheme(stored) ? stored : DEFAULT_THEME;
  paint(active.theme);
  globalThis.matchMedia(LIGHT_QUERY).addEventListener("change", () => {
    if (active.theme === "system") {
      paint(active.theme);
    }
  });
};
