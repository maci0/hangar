// Prints WCAG contrast ratios for the token pairs documented in docs/BRAND.md.
// Fails when a text pair drops below 4.5:1 or a non-text edge below 3:1.
// Reads solid hex tokens from src/web/ui/styles.css. The dark palette is the `@theme static` block.
// The light palette is the `:root.light` overrides, which fall back to the dark value.
// Run: bun run check:contrast
const MARKER = "package.json";
const TEXT_MIN = 4.5;
const EDGE_MIN = 3;
const CHANNEL_MAX = 255;
const LINEAR_CUTOFF = 0.039_28;
const LINEAR_DIVISOR = 12.92;
const GAMMA_OFFSET = 0.055;
const GAMMA_SCALE = 1.055;
const GAMMA_EXP = 2.4;
const LUMA = [0.2126, 0.7152, 0.0722] as const;
const HEX_PAIR_WIDTH = 2;
const HEX_RADIX = 16;
const CONTRAST_OFFSET = 0.05;

type Pair = { readonly fg: string; readonly bg: string; readonly min: number };

const TEXT_ON_SURFACES = ["bg", "bg-alt", "surface", "surface-2"] as const;
const PAIRS: ReadonlyArray<Pair> = [
  ...["text", "text-muted", "text-dim", "danger-text", "accent-2"].flatMap((fg) =>
    TEXT_ON_SURFACES.map((bg) => ({ fg, bg, min: TEXT_MIN })),
  ),
  { fg: "text", bg: "surface-3", min: TEXT_MIN },
  { fg: "text-on-accent", bg: "accent", min: TEXT_MIN },
  { fg: "text-on-accent", bg: "accent-hover", min: TEXT_MIN },
  { fg: "text-on-danger", bg: "danger", min: TEXT_MIN },
  { fg: "border", bg: "bg", min: EDGE_MIN },
  { fg: "border", bg: "surface", min: EDGE_MIN },
];

/** Walks up from this script until a directory holds the project marker file. */
const findRoot = async (start: string): Promise<string> => {
  let dir = start;
  while (!(await Bun.file(`${dir}/${MARKER}`).exists())) {
    const parent = dir.slice(0, dir.lastIndexOf("/"));
    if (parent === dir || parent === "") {
      throw new Error(`no ${MARKER} above ${start}`);
    }
    dir = parent;
  }
  return dir;
};

/** Collects `--name: #hex` declarations from the rule whose header is `selector`. */
const readTokens = (css: string, selector: string): Map<string, string> => {
  const start = css.indexOf(`${selector} {`);
  if (start === -1) {
    throw new Error(`no ${selector} block in styles.css`);
  }
  const block = css.slice(start, css.indexOf("}", start));
  return new Map([...block.matchAll(/--([a-z0-9\-]+):\s*(#[0-9a-f]{3,6})\b/gv)].map((m) => [m[1] ?? "", m[2] ?? ""]));
};

const channel = (hex: string, index: number): number => {
  const full = hex.length === 4 ? hex.slice(1).replaceAll(/./gv, "$&$&") : hex.slice(1);
  const value = Number.parseInt(full.slice(index * HEX_PAIR_WIDTH, (index + 1) * HEX_PAIR_WIDTH), HEX_RADIX) / CHANNEL_MAX;
  return value <= LINEAR_CUTOFF ? value / LINEAR_DIVISOR : ((value + GAMMA_OFFSET) / GAMMA_SCALE) ** GAMMA_EXP;
};

const luminance = (hex: string): number => LUMA.reduce((sum, weight, index) => sum + weight * channel(hex, index), 0);

const ratio = (a: string, b: string): number => {
  const [hi, lo] = [luminance(a), luminance(b)].toSorted((x, y) => y - x);
  return ((hi ?? 0) + CONTRAST_OFFSET) / ((lo ?? 0) + CONTRAST_OFFSET);
};

const css = await Bun.file(`${await findRoot(import.meta.dir)}/src/web/ui/styles.css`).text();
const dark = readTokens(css, "@theme static");
const light = new Map([...dark, ...readTokens(css, ":root.light")]);
let failures = 0;
for (const [theme, tokens] of [
  ["dark", dark],
  ["light", light],
] as const) {
  for (const { fg, bg, min } of PAIRS) {
    const fgHex = tokens.get(fg);
    const bgHex = tokens.get(bg);
    if (fgHex === undefined || bgHex === undefined) {
      throw new Error(`${theme}: token --${fg} or --${bg} is missing or not a solid hex`);
    }
    const value = ratio(fgHex, bgHex);
    const ok = value >= min;
    failures += ok ? 0 : 1;
    console.log(`${theme}\t${fg} on ${bg}\t${fgHex} ${bgHex}\t${value.toFixed(2)}\t${ok ? "ok" : `FAIL (min ${min})`}`);
  }
}
if (failures > 0) {
  throw new Error(`${failures} contrast pairs below their minimum`);
}
