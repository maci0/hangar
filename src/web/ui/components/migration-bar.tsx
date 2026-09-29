import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";
import type { MigrationTone, MigrationView } from "@/lib/migration";

const FILL_BY_TONE: Readonly<Record<MigrationTone, string>> = {
  active: "bg-accent",
  success: "bg-success",
  danger: "bg-danger",
  warn: "bg-warn",
};

const PERCENT_MAX = 100;

/** Progress of a running migration, with its status line and Cancel. Renders hidden while none runs. */
export const MigrationBar = ({ view, onCancel }: { readonly view: MigrationView; readonly onCancel: () => void }) => {
  const active = view.kind === "active";
  const percent = active ? view.percent : null;
  return (
    <div class={cn("mt-5", !active && "hidden")}>
      <div
        id="mig_progress"
        role="progressbar"
        aria-label="Migration progress"
        aria-valuemin={0}
        aria-valuemax={PERCENT_MAX}
        aria-valuenow={percent === null ? undefined : Math.round(percent)}
        class="mb-1.5 h-1 overflow-hidden rounded-xs bg-border"
      >
        <div
          class={cn("h-full rounded-xs transition-all duration-300 ease-in-out", FILL_BY_TONE[active ? view.tone : "active"])}
          style={{ width: `${percent ?? 0}%` }}
        />
      </div>
      <span id="mig_pct" role="status" aria-live="polite" class="text-xs text-fg-muted">
        {active ? view.label : ""}
      </span>
      <Button id="mig_cancel" variant="danger" class="ml-3 px-2.5 py-0.75 text-caption" data-action="cancelMigrate" onClick={onCancel}>
        Cancel
      </Button>
    </div>
  );
};
