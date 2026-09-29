import { Button } from "@/components/ui/button";

const ICON_BY_THEME: Readonly<Record<string, string>> = {
  system: "i-monitor",
  light: "i-sun",
  dark: "i-theme",
};

declare global {
  // Set by the legacy theme code in app.js.
  var hangarTheme: string | undefined;
}

/** Toolbar theme cycle. The legacy `toggleTheme` delegator handles the click and swaps the icon. */
export const ThemeToggle = () => (
  <Button
    class="theme-toggle-btn keep-mobile"
    data-action="toggleTheme"
    title="Toggle theme"
    aria-label="Toggle theme"
  >
    <svg class="ico" aria-hidden="true">
      <use href={`/icons.svg#${ICON_BY_THEME[globalThis.hangarTheme ?? "system"] ?? "i-monitor"}`} />
    </svg>
  </Button>
);
