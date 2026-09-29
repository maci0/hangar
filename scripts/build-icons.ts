// Builds the icon sprite (src/web/dist/icons.svg) and the browsable index
// (docs/brand/icons.html) from assets/icons/*.svg, the single source of truth.
const MARKER = "package.json";
const ICON_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/v;
const ROOT_ATTRS = 'viewBox="0 0 24 24"';
const STROKE_ATTRS = 'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
const SVG_BODY = /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" viewBox="0 0 24 24" fill="(none|currentColor)" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">(.+)<\/svg>\s*$/v;

type Icon = {
  readonly name: string;
  readonly fill: string;
  readonly body: string;
};

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

/** Reads one icon file and rejects anything off the 24px grid or off the shared stroke. */
const readIcon = async (dir: string, file: string): Promise<Icon> => {
  const name = file.replace(/\.svg$/v, "");
  if (!ICON_NAME.test(name)) {
    throw new Error(`${file}: name must be kebab-case`);
  }
  const match = SVG_BODY.exec(await Bun.file(`${dir}/${file}`).text());
  const fill = match?.[1];
  const body = match?.[2];
  if (fill === undefined || body === undefined) {
    throw new Error(`${file}: must be one <svg ${ROOT_ATTRS} ${STROKE_ATTRS}> element`);
  }
  return { name, fill, body };
};

const root = await findRoot(import.meta.dir);
const iconDir = `${root}/assets/icons`;
const files = [...new Bun.Glob("*.svg").scanSync(iconDir)].toSorted();
const icons = await Promise.all(files.map((file) => readIcon(iconDir, file)));

const symbols = icons
  .map(({ name, fill, body }) => `<symbol id="i-${name}" ${ROOT_ATTRS} fill="${fill}" ${STROKE_ATTRS}>${body}</symbol>`)
  .join("\n");
await Bun.write(`${root}/src/web/dist/icons.svg`, `<svg xmlns="http://www.w3.org/2000/svg">\n${symbols}\n</svg>\n`);

const cells = icons
  .map(
    ({ name }) =>
      `<li class="icon-cell"><svg class="icon-glyph" aria-hidden="true"><use href="#i-${name}"></use></svg><code>${name}</code></li>`,
  )
  .join("\n");
const page = `<!DOCTYPE html>
<html lang="en" class="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hangar icons</title>
<link rel="stylesheet" href="../../src/web/dist/ui.css">
<link rel="stylesheet" href="brand.css">
</head>
<body class="brand-page">
<main>
<h1>Icons</h1>
<p>${icons.length} icons on a 24px grid with a 2px round stroke. Source files live in <code>assets/icons</code>; use one as <code>&lt;use href="/icons.svg#i-name"&gt;</code>.</p>
<ul class="icon-grid">
${cells}
</ul>
</main>
<svg class="sprite" aria-hidden="true">
${symbols}
</svg>
</body>
</html>
`;
await Bun.write(`${root}/docs/brand/icons.html`, page);
