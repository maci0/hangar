import type { OsBrand } from "@/lib/vm";

type BrandRule = { readonly pattern: RegExp; readonly color: string; readonly text: string };

/** First match wins, so `openbsd` is tested before the general `bsd`. */
const BRAND_RULES: ReadonlyArray<BrandRule> = [
  { pattern: /ubuntu/v, color: "#E95420", text: "U" },
  { pattern: /fedora/v, color: "#3C6EB4", text: "F" },
  { pattern: /debian/v, color: "#A80030", text: "D" },
  { pattern: /alpine/v, color: "#0D597F", text: "A" },
  { pattern: /\barch\b/v, color: "#1793D1", text: "A" },
  { pattern: /rocky|alma|centos|rhel|red ?hat/v, color: "#10B981", text: "R" },
  { pattern: /openbsd/v, color: "#F2CA30", text: "O" },
  { pattern: /freebsd|\bbsd\b/v, color: "#AB2B28", text: "B" },
  { pattern: /windows|microsoft/v, color: "#0078D4", text: "W" },
  { pattern: /mac ?os|apple|darwin/v, color: "#555", text: "M" },
  { pattern: /linux/v, color: "#5B7A8C", text: "L" },
];

const ACCENT_COLOR = "var(--accent)";
const UNKNOWN_TEXT = "?";

/**
 * Emblem for the catalog cards, the VM header and the inventory. `hint` is a name or description;
 * `osLabel` is the guest OS label. An unknown OS gets the accent color and the hint's first letter.
 */
export const osBrand = (hint: string, osLabel: string): OsBrand => {
  const haystack = `${hint} ${osLabel}`.toLowerCase();
  const rule = BRAND_RULES.find(({ pattern }) => pattern.test(haystack));
  if (rule !== undefined) {
    return { color: rule.color, text: rule.text };
  }
  return { color: ACCENT_COLOR, text: (hint || osLabel || UNKNOWN_TEXT).charAt(0).toUpperCase() || UNKNOWN_TEXT };
};
