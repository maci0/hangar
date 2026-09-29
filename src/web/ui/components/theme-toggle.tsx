import { Button } from "@/components/ui/button";

/** Toolbar theme cycle. The legacy `toggleTheme` delegator handles the click and swaps the icon. */
export const ThemeToggle = () => (
  <Button class="btn theme-toggle-btn keep-mobile" data-action="toggleTheme" title="Toggle theme" aria-label="Toggle theme">
    <svg class="ico" aria-hidden="true">
      <use href="#i-theme" />
    </svg>
  </Button>
);
