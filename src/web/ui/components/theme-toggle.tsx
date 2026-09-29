import { useEffect, useState } from "preact/hooks";
import { Button } from "@/components/ui/button";
import { currentTheme, subscribeTheme, themeLabel, type Theme } from "@/lib/theme";

const ICON_BY_THEME: Readonly<Record<Theme, string>> = {
  system: "i-monitor",
  light: "i-sun",
  dark: "i-theme",
};

/** Toolbar theme cycle. The icon and the accessible name follow the active theme. */
export const ThemeToggle = ({ onCycle }: { readonly onCycle: () => void }) => {
  const [theme, setTheme] = useState<Theme>(currentTheme);
  useEffect(() => subscribeTheme(setTheme), []);
  const label = themeLabel(theme);
  return (
    <Button class="theme-toggle-btn" onClick={onCycle} title={label} aria-label={label}>
      <svg class="ico size-3.75" aria-hidden="true">
        <use href={`/icons.svg#${ICON_BY_THEME[theme]}`} />
      </svg>
    </Button>
  );
};
