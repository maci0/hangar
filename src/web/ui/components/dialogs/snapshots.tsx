import { useState } from "preact/hooks";
import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogTitle, useDialogTask } from "@/components/ui/dialog";
import { FieldError, invalidProps } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

const TAG_MAX_LENGTH = 255;

export type Snapshot = {
  readonly tag: string;
  /** Creation time as reported by qemu-img; empty when unknown. */
  readonly when: string;
  /** Relative age of `when` ("3 hours ago"), for the tooltip; empty when unknown. */
  readonly age: string;
};

export type SnapshotList =
  | { readonly kind: "loading" }
  | { readonly kind: "failed" }
  | { readonly kind: "ready"; readonly items: ReadonlyArray<Snapshot> };

export type SnapshotsState = {
  readonly vmName: string;
  /** Display label of the VM state ("Running"). */
  readonly statusLabel: string;
  /** Running or paused: revert needs the VM powered off. */
  readonly running: boolean;
  readonly list: SnapshotList;
  /** Takes a snapshot; resolves whether it was taken (then the name field clears). */
  readonly take: (tag: string) => Promise<boolean>;
  /** Confirms, then reverts; resolves whether the VM was reverted (then the dialog closes). */
  readonly revert: (tag: string) => Promise<boolean>;
  /** Confirms, deletes, then reloads the list. */
  readonly remove: (tag: string) => Promise<void>;
};

const CONTROL_CHAR = /\p{Cc}/u;

/** Returns the problem with `tag`, or an empty string. */
const validateTag = (tag: string): string => {
  if (tag === "") {
    return "Enter a snapshot name.";
  }
  return tag.length > TAG_MAX_LENGTH || tag.includes("..") || CONTROL_CHAR.test(tag) ? "Snapshot name is invalid." : "";
};

const TakeForm = ({ take }: { readonly take: SnapshotsState["take"] }) => {
  const [tag, setTag] = useState("");
  const [error, setError] = useState("");
  const [taking, setTaking] = useState(false);

  const submit = () => {
    const trimmed = tag.trim();
    setError(validateTag(trimmed));
    if (validateTag(trimmed) !== "") {
      return;
    }
    const takeAndClear = async () => {
      setTaking(true);
      try {
        if (await take(trimmed)) {
          setTag("");
        }
      } finally {
        setTaking(false);
      }
    };
    takeAndClear().catch(reportError);
  };

  return (
    <form
      noValidate
      class="mb-3"
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      <div class="flex items-end gap-2">
        <div class="grid flex-1 gap-1">
          <Label htmlFor="s_tag">Snapshot name</Label>
          <Input
            id="s_tag"
            type="text"
            placeholder="e.g. Before update"
            value={tag}
            onInput={(event) => {
              setTag(event.currentTarget.value);
              setError("");
            }}
            {...invalidProps(error, "err_s_tag")}
          />
        </div>
        <Button type="submit" variant="primary" disabled={taking}>
          {taking ? "Taking…" : "Take"}
        </Button>
      </div>
      <FieldError id="err_s_tag">{error}</FieldError>
    </form>
  );
};

type SnapshotRowProps = {
  readonly snapshot: Snapshot;
  readonly running: boolean;
  readonly busy: boolean;
  readonly onRevert: () => void;
  readonly onRemove: () => void;
};

const ROW_BUTTON = "min-h-5.5 px-2 py-0.5 text-caption";

const SnapshotRow = ({ snapshot, running, busy, onRevert, onRemove }: SnapshotRowProps) => (
  <div class="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-border-soft px-2.5 py-2 last:border-b-0">
    <span aria-hidden="true" class="inline-flex size-8.5 flex-none items-center justify-center rounded-md bg-accent-soft text-accent">
      <Icon name="snapshot" class="ico size-4.25" />
    </span>
    <div class="flex min-w-0 flex-col">
      <strong class="text-field break-words">{snapshot.tag}</strong>
      <small class="text-caption text-fg-dim" title={snapshot.age}>
        {snapshot.when === "" ? "Saved state" : `Taken ${snapshot.when}`}
      </small>
    </div>
    <div class="ml-auto flex gap-1.25 max-phone:ml-0 max-phone:w-full">
      <Button
        type="button"
        class={ROW_BUTTON}
        disabled={running || busy}
        title={running ? "Power off the VM before reverting" : undefined}
        aria-label={`Revert to snapshot ${snapshot.tag}`}
        onClick={onRevert}
      >
        {busy ? "…" : "Revert"}
      </Button>
      <Button type="button" variant="danger" class={ROW_BUTTON} disabled={busy} aria-label={`Delete snapshot ${snapshot.tag}`} onClick={onRemove}>
        {busy ? "…" : "Delete"}
      </Button>
    </div>
  </div>
);

const MESSAGE = "p-4.5 text-center text-field text-fg-dim";

type ItemsProps = {
  readonly state: SnapshotsState;
  readonly busy: boolean;
  readonly run: (task: () => Promise<boolean>) => void;
};

const SnapshotItems = ({ state, busy, run }: ItemsProps) => {
  const { list } = state;
  if (list.kind === "loading") {
    return <div class={MESSAGE}>Loading snapshots…</div>;
  }
  if (list.kind === "failed") {
    return <div class={MESSAGE}>Failed to load snapshots</div>;
  }
  if (list.items.length === 0) {
    return <div class={MESSAGE}>No snapshots yet. Take one above to capture this VM's disk state, you can revert to or delete it here later.</div>;
  }
  return (
    <>
      {list.items.map((snapshot) => (
        <SnapshotRow
          key={snapshot.tag}
          snapshot={snapshot}
          running={state.running}
          busy={busy}
          onRevert={() => run(() => state.revert(snapshot.tag))}
          onRemove={() =>
            run(async () => {
              await state.remove(snapshot.tag);
              return false;
            })
          }
        />
      ))}
    </>
  );
};

const SnapshotMeta = ({ state }: { readonly state: SnapshotsState }) => (
  <div id="snapMeta" role="status" aria-live="polite" class="-mt-0.5 mb-2.5 flex flex-wrap items-center gap-1.75 text-xs text-fg-muted">
    <strong class="text-fg">{state.vmName}</strong>
    <span>{state.statusLabel}</span>
    {state.running && <span class="text-warn">Revert and delete require the VM to be powered off.</span>}
  </div>
);

const SnapshotsContent = ({ state }: { readonly state: SnapshotsState }) => {
  // One flag for every row button: a revert or delete in flight blocks the others.
  const { busy, run } = useDialogTask();
  return (
    <>
      <DialogBody>
        <SnapshotMeta state={state} />
        <TakeForm take={state.take} />
        <div id="snaplist" role="status" aria-live="polite" class="max-h-75 overflow-y-auto rounded-md border border-border bg-bg">
          <SnapshotItems state={state} busy={busy} run={run} />
        </div>
      </DialogBody>
      <DialogFooter>
        <DialogClose>Close</DialogClose>
      </DialogFooter>
    </>
  );
};

export type SnapshotsDialogProps = {
  readonly state: SnapshotsState;
  readonly onClose: () => void;
};

/** Snapshot Manager. The app pushes the list and VM state; actions call back into it. */
export const SnapshotsDialog = ({ state, onClose }: SnapshotsDialogProps) => (
  <Dialog id="snapdlg" titleId="snap-title" onClose={onClose}>
    <DialogTitle id="snap-title">Snapshot Manager</DialogTitle>
    <SnapshotsContent state={state} />
  </Dialog>
);
