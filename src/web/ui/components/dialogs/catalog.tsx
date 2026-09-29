import { useState } from "preact/hooks";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogTitle, useDialogTask } from "@/components/ui/dialog";

export type CatalogEntry = {
  readonly id: string;
  readonly name: string;
  /** Guest OS family label ("Linux"). */
  readonly os: string;
  readonly description: string;
  readonly cpuCores: number;
  /** Memory as a display label ("2 GiB"). */
  readonly memory: string;
  readonly diskGb: number;
  /** Emblem background: any CSS color, chosen per distribution. */
  readonly brandColor: string;
  /** One or two letters on the emblem. */
  readonly monogram: string;
};

export type CatalogList =
  | { readonly kind: "loading" }
  | { readonly kind: "failed" }
  | { readonly kind: "empty" }
  | { readonly kind: "ready"; readonly items: ReadonlyArray<CatalogEntry> };

export type CatalogState = {
  readonly list: CatalogList;
  /** Creates a VM from the template; resolves whether it was created (then the dialog closes). */
  readonly create: (id: string) => Promise<boolean>;
};

const MESSAGE = "p-5 text-center text-field text-fg-muted";

type CardProps = {
  readonly entry: CatalogEntry;
  readonly pending: boolean;
  readonly disabled: boolean;
  readonly onCreate: () => void;
};

const SPEC = "rounded-sm bg-inset px-1.75 py-0.5 text-caption whitespace-nowrap text-fg-muted tabular-nums";

const CatalogCard = ({ entry, pending, disabled, onCreate }: CardProps) => (
  <div class="cat-card flex items-center gap-3.5 rounded-md border border-border bg-surface px-4 py-3.5 transition-colors hover:border-accent max-phone:flex-wrap">
    <div
      aria-hidden="true"
      class="cat-emblem flex size-11 flex-none items-center justify-center rounded-lg text-xl leading-none font-bold text-white"
      style={{ background: entry.brandColor }}
    >
      {entry.monogram}
    </div>
    <div class="min-w-0 flex-1">
      <div class="truncate text-sm font-semibold text-fg">{entry.name}</div>
      <div class="mt-px mb-1 text-caption font-bold tracking-wide text-fg-dim uppercase">{entry.os}</div>
      <div class="mb-1.75 text-xs leading-snug text-fg-muted">{entry.description}</div>
      <div class="flex flex-wrap gap-1.25">
        <span class={SPEC}>{entry.cpuCores} vCPU</span>
        <span class={SPEC}>{entry.memory} RAM</span>
        <span class={SPEC}>{entry.diskGb} GB disk</span>
      </div>
    </div>
    <Button
      type="button"
      variant="primary"
      class="cat-create flex-none self-center max-phone:w-full"
      data-catalog-id={entry.id}
      aria-label={`Create VM from ${entry.name}`}
      disabled={disabled}
      onClick={onCreate}
    >
      {pending ? "Creating…" : "Create"}
    </Button>
  </div>
);

const CatalogItems = ({ state }: { readonly state: CatalogState }) => {
  const { busy, run } = useDialogTask();
  const [pendingId, setPendingId] = useState("");
  const { list } = state;
  if (list.kind === "loading") {
    return (
      <div id="catalogList" role="status" class={MESSAGE}>
        Loading catalog…
      </div>
    );
  }
  if (list.kind === "failed") {
    return (
      <div id="catalogList" role="alert" class={MESSAGE}>
        Failed to load catalog.
      </div>
    );
  }
  if (list.kind === "empty") {
    return (
      <div id="catalogList" role="status" class={MESSAGE}>
        No templates available.
      </div>
    );
  }
  return (
    <div id="catalogList" class="catalog-grid grid grid-cols-catalog gap-3">
      {list.items.map((entry) => (
        <CatalogCard
          key={entry.id}
          entry={entry}
          pending={busy && pendingId === entry.id}
          disabled={busy}
          onCreate={() => {
            setPendingId(entry.id);
            run(() => state.create(entry.id));
          }}
        />
      ))}
    </div>
  );
};

export type CatalogDialogProps = {
  readonly state: CatalogState;
  readonly onClose: () => void;
};

/** VM Catalog. The app fetches the templates and pushes the list; Create calls back into it. */
export const CatalogDialog = ({ state, onClose }: CatalogDialogProps) => (
  <Dialog id="catalogdlg" titleId="catalog-title" class="w-215" onClose={onClose}>
    <DialogTitle id="catalog-title">VM Catalog</DialogTitle>
    <DialogBody>
      <p class="mb-3 text-xs text-fg-muted">Choose a template to create a pre-configured VM.</p>
      <CatalogItems state={state} />
    </DialogBody>
    <DialogFooter>
      <DialogClose>Close</DialogClose>
    </DialogFooter>
  </Dialog>
);
