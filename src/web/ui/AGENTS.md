# AGENTS.md: src/web/ui (Preact + Tailwind source)

## Purpose
Typed source for the browser UI: Preact components, shadcn-style primitives, and the
Tailwind v4 entry sheet. Bundled by `scripts/build-web.ts` into `src/web/dist/ui.js` and
`ui.css` (gitignored), which `web_server.zig` embeds and serves as `/ui.js` and `/ui.css`.
The legacy `../app.js` and `../app.css` still own everything not yet ported here.

## Ownership
- `main.tsx`: entry. Replaces a legacy DOM node with its Preact component.
- `components/ui/`: shadcn-style primitives (cva variants, `cn` merge). `components.json`
  at the repo root maps the shadcn CLI aliases here.
- `components/`: feature components.
- `lib/cn.ts`: class merge helper.
- `styles.css`: Tailwind `theme` and `utilities` layers only (no preflight while `app.css`
  owns resets). `@theme inline` exposes the `app.css` tokens as utilities.

## Local Contracts
- Tokens are declared once, in `app.css` `:root` and `:root.light`. `styles.css` maps them
  and never redefines a value. No hex, px radius, or font stack in a component.
- Ported components keep the legacy ids, classes, and `data-action` attributes so the
  delegated click handler and the Playwright suites keep working unchanged.
- Strict CSP (`script-src 'self'`): no inline handlers; actions go through `data-action`
  until the surrounding surface is fully ported.
- Toolchain is Bun only. `bun run lint` (oxlint strict preset, Rika anti-slop,
  `@shadcn/lint`), `bun run typecheck`, and `bun run build:web` must all pass with no
  disabled rules. oxlint is pinned to 1.57.0 because the Rika 0.8.1 preset names rules
  that later oxlint versions dropped; move both together.
- Function components and helpers are `const` arrow functions (the preset's `func-style`).

## Work Guidance
- Port one surface at a time: build the component, remove its legacy code and CSS in the
  same change, and keep `zig build web-e2e` green.

## Verification
`bun run lint && bun run typecheck && zig build web-e2e`.
