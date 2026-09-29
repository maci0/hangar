// Builds the Preact UI (src/web/ui) into src/web/dist/{ui.js,ui.css}.
// Run by zig build and bun run build:web. web_server.zig embeds the output.
const MARKER = "package.json";

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

const root = await findRoot(import.meta.dir);
const dist = `${root}/src/web/dist`;

const bundle = await Bun.build({
  entrypoints: [`${root}/src/web/ui/main.tsx`],
  outdir: dist,
  naming: "ui.js",
  minify: true,
  target: "browser",
});
if (!bundle.success) {
  throw new AggregateError(bundle.logs, "ui.js bundle failed");
}
await Bun.$`bunx tailwindcss -i ${root}/src/web/ui/styles.css -o ${dist}/ui.css --minify`.quiet();
