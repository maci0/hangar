# Hangar brand guide

Hangar is an operator console for QEMU virtual machines. The look is flat, dense, and quiet: color marks state, and one muted blue marks the primary action.

## Tokens

One source per value, consumed everywhere.

- Colors: the dark palette (default) is the first `@theme static` block of `src/web/ui/styles.css`; the light palette overrides the same names under `:root.light` in the same file. Utilities read them through `@theme inline` (`bg-surface`, `text-fg-muted`, `border-border-soft`).
- Radius, fonts, type steps and animations: the second `@theme static` block of the same file.
- No hex value, pixel radius, or font stack appears in a component.

## Palette and contrast

Ratios come from `bun run check:contrast`, which fails below 4.5:1 for text and 3:1 for edges. Text pairs below are the worst case across `--bg`, `--bg-alt`, `--surface`, `--surface-2`.

| Token | Dark | Light | Worst text ratio (dark / light) |
| --- | --- | --- | --- |
| `--text` | `#dde1e6` | `#22272d` | 11.01 / 12.94 |
| `--text-muted` | `#9aa1a9` | `#555c64` | 5.54 / 5.83 |
| `--text-dim` | `#8d949c` | `#646c75` | 4.71 / 4.58 |
| `--accent` (fill, white text) | `#3e6f9e` | `#2a6496` | 5.29 / 6.25 |
| `--danger` (fill, white text) | `#b8493f` | `#b03f38` | 5.17 / 5.81 |
| `--danger-text` | `#e07a6c` | `#b03f38` | 4.94 / 5.00 |
| `--border` (edge) | `#798089` | `#828892` | 4.01 / 3.24 (3:1 minimum) |

`--text`, `--text-muted`, and `--text-dim` are three distinct steps. Never merge two.

## Logo

A flat `--accent` rounded square with one white "H" (`src/web/favicon.svg`). The sidebar mark and About emblem use the same shape.

- Do: use it at 16px or larger on any surface, with the radius token for its size.
- Don't: add a gradient, a shadow, a second letter, or a different typeface.

## Typography

Sans is the platform UI stack, mono is `ui-monospace`. There is no webfont because this is a desktop-style console that should match the desktop around it. Body text is 12 to 13px, labels 11px uppercase with tracking.

## Icons

36 icons in `assets/icons/`: 24px grid, 2px round stroke, kebab-case names. `bun run build:web` validates them and writes `/icons.svg` and the index at `docs/brand/icons.html`. Add an icon by adding a file; do not draw inline SVG in a component.

## Voice

Plain and specific. Name the object and the result: "Snapshot deleted", not "Success". Use VMware Workstation terms: Power On, Suspend, Take Snapshot, VM Library.

- Do: "Disk resize failed: the guest disk is larger than the requested size."
- Don't: "Oops, something went wrong!"
- Avoid: hype words (seamless, unlock, elevate), em dashes, exclamation marks, emoji in controls.
