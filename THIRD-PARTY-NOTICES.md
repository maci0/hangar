# Third-party notices

Every third-party artifact that ships inside this repository or inside a build
output. Each entry names the exact version or commit, where it comes from, and
the license that governs its use. Update this file in the same change that
bumps, re-vendors, adds, or removes a dependency.

## Bundled in the web UI (`src/web/`)

These files are `@embedFile`'d by the daemon and served to browsers, so their
licenses travel with the shipped binary. Every bundle also carries a provenance
header on its first lines; the header and this table must agree.

| File | Package | Version | Source | License |
| --- | --- | --- | --- | --- |
| `novnc.js` | noVNC | not recorded | https://github.com/novnc/noVNC (bundled `dist`) | MPL-2.0 |
| `spice.js` | spice-html5 | not recorded | https://gitlab.freedesktop.org/spice/spice-html5 (esbuild bundle) | LGPL-3.0-or-later |
| `elk.js` | elkjs | 0.11.1 | npm `elkjs`, `lib/elk.bundled.js` | EPL-2.0 |
| `xterm.js` | @xterm/xterm | 6.0.0 | npm `@xterm/xterm`, `lib/xterm.js` | MIT |
| `xterm.css` | @xterm/xterm | 6.0.0 | npm `@xterm/xterm`, `css/xterm.css` | MIT |
| `xterm-fit.js` | @xterm/addon-fit | 0.11.0 | npm `@xterm/addon-fit`, `lib/addon-fit.js` | MIT |
| `xterm-webgl.js` | @xterm/addon-webgl | 0.19.0 | npm `@xterm/addon-webgl`, `lib/addon-webgl.js` | MIT |
| `dist/ui.js` (built from `ui/`) | preact | 10.29.8 | npm `preact`, bundled by Bun | MIT |
| `dist/ui.js` | clsx | 2.1.1 | npm `clsx`, bundled by Bun | MIT |
| `dist/ui.js` | class-variance-authority | 0.7.1 | npm `class-variance-authority`, bundled by Bun | Apache-2.0 |
| `dist/ui.js` | tailwind-merge | 3.7.0 | npm `tailwind-merge`, bundled by Bun | MIT |
| `dist/ui.css` | tailwindcss (theme, preflight, utilities) | 4.3.3 | npm `tailwindcss`, compiled by `@tailwindcss/cli` | MIT |

`novnc.js` and `spice.js` have no registry pin. Their upstream version must be
recorded in their header and in the table above at the next re-vendor; until
then the exact source they came from is not reproducible from this repository.

Obligations that survive shipping:

- **spice-html5 (LGPL-3.0-or-later)** is the only copyleft component in the
  browser payload. It is used unmodified and reachable only through
  `wsproxy.zig`'s SPICE relay. Redistribution must carry this notice, the
  license text, and the corresponding source; a receiver must be able to replace
  the library with a modified build.
- **noVNC (MPL-2.0)** requires that modifications to MPL-covered files be
  published under MPL-2.0. The bundle is unmodified, so nothing is owed today;
  a re-vendor that edits the file makes that obligation live.
- **elkjs (EPL-2.0)** carries a patent grant and a secondary-licensing option.
  The unmodified bundle is used as-is.

## Build and test dependencies

Declared, not redistributed. Pinned by `bun.lock` (with integrity hashes) and
by `build.zig.zon` (with content hashes), so a given checkout builds the same
artifacts.

| Package | Version | Used for | License |
| --- | --- | --- | --- |
| @playwright/test (and `playwright`, `playwright-core`) | 1.62.1 | e2e and visual suites | Apache-2.0 |
| @webgpu/types | 0.1.74 | WebGPU type declarations for `src/web/ui/lib/presenter.ts` (no code shipped) | BSD-3-Clause |
| @xterm/xterm, @xterm/addon-fit, @xterm/addon-webgl, elkjs | see above | sources for re-vendoring the browser bundles | see above |
| zig_webui | 2.5.0-beta.4 | native WebView wrapper (`zig build webui`) | not stated in the tarball; upstream declares MIT |
| webui (transitive of zig_webui) | 2.5.0-beta.4 | WebView assets, linked into the wrapper | not stated in the tarball; upstream is MIT |

The pinned `zig_webui` and `webui` tarballs ship no `LICENSE` file. Their
licenses are asserted from upstream and have not been verified from the
downloaded artifact.
